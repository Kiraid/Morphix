package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/iot"
)

var (
	region = os.Getenv("AWS_REGION")
)

var iotClient *iot.Client

var (
	credsProvider aws.CredentialsProvider
)

func init() {
	cfg, err := config.LoadDefaultConfig(context.Background(), config.WithRegion(region))
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}
	iotClient = iot.NewFromConfig(cfg)
	credsProvider = cfg.Credentials
}

type IoTAuthResponse struct {
	WSSURL   string `json:"wss_url"`
	ClientID string `json:"client_id"`
	Expiry   int64  `json:"expiry"`
}

func handler(ctx context.Context, req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	if req.HTTPMethod == http.MethodOptions {
		return corsResponse(http.StatusOK, ""), nil
	}

	jobID := req.QueryStringParameters["job_id"]
	if jobID == "" {
		return errResponse(http.StatusBadRequest, "job_id query parameter is required"), nil
	}

	clientID := fmt.Sprintf("morphix-%s-%d", jobID, time.Now().UnixMilli())

	desc, err := iotClient.DescribeEndpoint(ctx, &iot.DescribeEndpointInput{
		EndpointType: strPtr("iot:Data-ATS"),
	})
	if err != nil {
		log.Printf("DescribeEndpoint error: %v", err)
		return errResponse(http.StatusInternalServerError, "failed to get IoT endpoint"), nil
	}

	endpoint := *desc.EndpointAddress

	wssURL, err := presignIoTWebSocketURL(ctx, endpoint, region)
	if err != nil {
		log.Printf("SigV4 presign error: %v", err)
		return errResponse(http.StatusInternalServerError, "failed to sign IoT URL"), nil
	}

	resp := IoTAuthResponse{
		WSSURL:   wssURL,
		ClientID: clientID,
		Expiry:   time.Now().Add(1 * time.Hour).Unix(),
	}

	body, _ := json.Marshal(resp)
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusOK,
		Headers:    corsHeaders(),
		Body:       string(body),
	}, nil
}

func presignIoTWebSocketURL(ctx context.Context, endpoint, awsRegion string) (string, error) {
	creds, err := credsProvider.Retrieve(ctx)
	if err != nil {
		return "", fmt.Errorf("retrieve credentials: %w", err)
	}

	now := time.Now().UTC()
	dateStamp := now.Format("20060102")
	amzDate := now.Format("20060102T150405Z")

	// Match AWS Java AwsIotWebSocketUrlSigner: service name "iotdata", signed query
	// excludes X-Amz-Security-Token and X-Amz-Expires; session token is appended after signature.
	service := "iotdata"
	algorithm := "AWS4-HMAC-SHA256"

	credential := creds.AccessKeyID + "/" + dateStamp + "/" + awsRegion + "/" + service + "/aws4_request"

	hostCanon := strings.ToLower(strings.TrimSpace(endpoint))
	params := url.Values{}
	params.Set("X-Amz-Algorithm", algorithm)
	params.Set("X-Amz-Credential", credential)
	params.Set("X-Amz-Date", amzDate)
	params.Set("X-Amz-SignedHeaders", "host")

	canonicalQueryString := params.Encode() // sorted: Algorithm, Credential, Date, SignedHeaders

	canonicalRequest := "GET\n/mqtt\n" + canonicalQueryString + "\n" +
		"host:" + hostCanon + "\n\n" +
		"host\n" +
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

	credentialScope := dateStamp + "/" + awsRegion + "/" + service + "/aws4_request"
	stringToSign := strings.Join([]string{
		algorithm,
		amzDate,
		credentialScope,
		hexEncode(sha256Hash([]byte(canonicalRequest))),
	}, "\n")

	signingKey := getSignatureKey(creds.SecretAccessKey, dateStamp, awsRegion, service)
	signature := hexEncode(hmacSHA256(signingKey, []byte(stringToSign)))

	wssURL := fmt.Sprintf("wss://%s/mqtt?%s&X-Amz-Signature=%s", endpoint, canonicalQueryString, signature)
	if creds.SessionToken != "" {
		wssURL += "&X-Amz-Security-Token=" + url.QueryEscape(creds.SessionToken)
	}

	return wssURL, nil
}

func sha256Hash(data []byte) []byte {
	hash := sha256.Sum256(data)
	return hash[:]
}

func hmacSHA256(key, data []byte) []byte {
	h := hmac.New(sha256.New, key)
	h.Write(data)
	return h.Sum(nil)
}

func hexEncode(data []byte) string {
	return hex.EncodeToString(data)
}

func getSignatureKey(secretKey, dateStamp, regionName, serviceName string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secretKey), []byte(dateStamp))
	kRegion := hmacSHA256(kDate, []byte(regionName))
	kService := hmacSHA256(kRegion, []byte(serviceName))
	kSigning := hmacSHA256(kService, []byte("aws4_request"))
	return kSigning
}

func strPtr(s string) *string { return &s }

func corsHeaders() map[string]string {
	return map[string]string{
		"Access-Control-Allow-Origin":  "*",
		"Access-Control-Allow-Methods": "GET, OPTIONS",
		"Access-Control-Allow-Headers": "Content-Type",
		"Content-Type":                 "application/json",
	}
}

func corsResponse(code int, body string) events.APIGatewayProxyResponse {
	return events.APIGatewayProxyResponse{StatusCode: code, Headers: corsHeaders(), Body: body}
}

func errResponse(code int, msg string) events.APIGatewayProxyResponse {
	b, _ := json.Marshal(map[string]string{"error": msg})
	return events.APIGatewayProxyResponse{StatusCode: code, Headers: corsHeaders(), Body: string(b)}
}

func main() {
	lambda.Start(handler)
}