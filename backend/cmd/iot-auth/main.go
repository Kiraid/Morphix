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
	"os"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/iot"
)

var (
	region = os.Getenv("AWS_REGION")
)


var iotClient *iot.Client


type awsCredentials struct {
	AccessKeyID     string
	SecretAccessKey string
	SessionToken    string
}

var resolvedCreds awsCredentials

func init() {
	cfg, err := config.LoadDefaultConfig(context.Background(), config.WithRegion(region))
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}
	iotClient = iot.NewFromConfig(cfg)

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		log.Fatalf("failed to retrieve AWS credentials: %v", err)
	}
	resolvedCreds = awsCredentials{
		AccessKeyID:     creds.AccessKeyID,
		SecretAccessKey: creds.SecretAccessKey,
		SessionToken:    creds.SessionToken,
	}
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


	wssURL, err := signIoTWebSocketURL(endpoint, region, resolvedCreds)
	if err != nil {
		log.Printf("SigV4 signing error: %v", err)
		return errResponse(http.StatusInternalServerError, "failed to sign IoT URL"), nil
	}

	resp := IoTAuthResponse{
		WSSURL:   wssURL,
		ClientID: clientID,
		Expiry: time.Now().Add(1 * time.Hour).Unix(),
	}

	body, _ := json.Marshal(resp)
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusOK,
		Headers:    corsHeaders(),
		Body:       string(body),
	}, nil
}


func signIoTWebSocketURL(endpoint, awsRegion string, creds awsCredentials) (string, error) {
	now := time.Now().UTC()
	datestamp := now.Format("20060102")         // YYYYMMDD
	datetimestamp := now.Format("20060102T150405Z") // YYYYMMDDTHHmmssZ

	service := "iotdevicegateway"
	algorithm := "AWS4-HMAC-SHA256"
	credentialScope := strings.Join([]string{datestamp, awsRegion, service, "aws4_request"}, "/")
	credential := creds.AccessKeyID + "/" + credentialScope

	queryParams := []string{
		"X-Amz-Algorithm=" + algorithm,
		"X-Amz-Credential=" + urlEncode(credential),
		"X-Amz-Date=" + datetimestamp,
		"X-Amz-Expires=3600",
		"X-Amz-SignedHeaders=host",
	}
	if creds.SessionToken != "" {
		queryParams = append(queryParams, "X-Amz-Security-Token="+urlEncode(creds.SessionToken))
	}

	sortStrings(queryParams)
	canonicalQueryString := strings.Join(queryParams, "&")


	canonicalURI := "/mqtt"
	canonicalHeaders := "host:" + endpoint + "\n"
	signedHeaders := "host"

	payloadHash := sha256Hex("")

	canonicalRequest := strings.Join([]string{
		"GET",
		canonicalURI,
		canonicalQueryString,
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	}, "\n")

	stringToSign := strings.Join([]string{
		algorithm,
		datetimestamp,
		credentialScope,
		sha256Hex(canonicalRequest),
	}, "\n")


	signingKey := deriveSigningKey(creds.SecretAccessKey, datestamp, awsRegion, service)

	signature := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))

	finalQuery := canonicalQueryString + "&X-Amz-Signature=" + signature

	wssURL := fmt.Sprintf("wss://%s/mqtt?%s", endpoint, finalQuery)
	return wssURL, nil
}


func hmacSHA256(key []byte, data string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(data))
	return h.Sum(nil)
}

func sha256Hex(data string) string {
	h := sha256.New()
	h.Write([]byte(data))
	return hex.EncodeToString(h.Sum(nil))
}


func deriveSigningKey(secret, date, awsRegion, service string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secret), date)
	kRegion := hmacSHA256(kDate, awsRegion)
	kService := hmacSHA256(kRegion, service)
	kSigning := hmacSHA256(kService, "aws4_request")
	return kSigning
}


func urlEncode(s string) string {
	var b strings.Builder
	for _, c := range s {
		switch {
		case c >= 'A' && c <= 'Z',
			c >= 'a' && c <= 'z',
			c >= '0' && c <= '9',
			c == '-', c == '_', c == '.', c == '~':
			b.WriteRune(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
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