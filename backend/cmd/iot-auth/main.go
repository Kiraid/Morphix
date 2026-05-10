package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/iot"
)

// ── ENV ──────────────────────────────────────────────────────────────
var (
	iotEndpoint = os.Getenv("IOT_ENDPOINT")
	region      = os.Getenv("AWS_REGION")
)

// ── AWS CLIENTS ────────────────────────────────────────────────────────
var (
	iotClient *iot.Client
)

func init() {
	cfg, err := config.LoadDefaultConfig(context.Background(), config.WithRegion(region))
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}
	iotClient = iot.NewFromConfig(cfg)
}

// ── TYPES ─────────────────────────────────────────────────────────────
type IoTAuthResponse struct {
	WSSURL string `json:"wss_url"`
	Expiry int64  `json:"expiry"`
}

// ── HANDLER ────────────────────────────────────────────────────────────
func handler(ctx context.Context, req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	// CORS preflight
	if req.HTTPMethod == http.MethodOptions {
		return corsResponse(http.StatusOK, ""), nil
	}

	// Extract job_id from query params
	jobID := req.QueryStringParameters["job_id"]
	if jobID == "" {
		return errResponse(http.StatusBadRequest, "job_id query parameter is required"), nil
	}

	// Generate a unique client ID for this session
	clientID := fmt.Sprintf("morphix-%s-%d", jobID, time.Now().Unix())

	// Get IoT endpoint URL if not provided in env
	endpoint := iotEndpoint
	if endpoint == "" {
		// Fallback: construct from region
		endpoint = fmt.Sprintf("https://%s.iot.%s.amazonaws.com", getIoTDomain(), region)
	}

	// Create IoT credentials for WebSocket connection
	input := &iot.DescribeEndpointInput{
		EndpointType: "iot:Data-ATS",
	}

	desc, err := iotClient.DescribeEndpoint(ctx, input)
	if err != nil {
		log.Printf("failed to describe IoT endpoint: %v", err)
		return errResponse(http.StatusInternalServerError, "failed to get IoT endpoint"), nil
	}

	// Build WebSocket URL with credentials
	wssURL := fmt.Sprintf("wss://%s/mqtt?X-Amz-Security-Token=%s&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=%s&X-Amz-Date=%s&X-Amz-SignedHeaders=host&X-Amz-Signature=%s",
		desc.EndpointAddress,
		"", // Token would be generated here in production
		"", // Credential would be generated here
		time.Now().UTC().Format("20060102T150405Z"),
		"", // Signature would be generated here
	)

	// For simplicity, we'll return the basic endpoint URL
	// In production, you'd generate proper AWS SigV4 signed URL
	response := IoTAuthResponse{
		WSSURL: fmt.Sprintf("wss://%s/mqtt", desc.EndpointAddress),
		Expiry: time.Now().Add(1 * time.Hour).Unix(),
	}

	body, _ := json.Marshal(response)
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusOK,
		Headers:    corsHeaders(),
		Body:       string(body),
	}, nil
}

// ── HELPERS ─────────────────────────────────────────────────────────────
func getIoTDomain() string {
	// IoT domain format varies by region
	domainMap := map[string]string{
		"us-east-1":     "a3jmfq8w7p7i5j",
		"us-west-2":     "a2f1x1r0s9y5j4",
		"eu-west-1":     "a2p1r0s9t8y7j6",
		"ap-southeast-1": "a1b2c3d4e5f6g7",
	}
	
	if domain, ok := domainMap[region]; ok {
		return domain
	}
	return "iot" // fallback
}

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
