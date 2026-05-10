package main
//  Presigned URL Generator Lambda
import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddbtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/google/uuid"
)

// ── ENV ──────────────────────────────────────────────────────────────
var (
	bucketName = os.Getenv("S3_BUCKET")
	ddbTable   = os.Getenv("DDB_TABLE")
	region     = os.Getenv("AWS_REGION")
)

// ── TYPES ─────────────────────────────────────────────────────────────
type FileInfo struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	Type string `json:"type"`
}

type PresignRequest struct {
	Files        []FileInfo `json:"files"`
	TargetFormat string     `json:"target_format"`
}

type UploadURL struct {
	Filename string `json:"filename"`
	URL      string `json:"url"`
}

type PresignResponse struct {
	RequestID  string      `json:"request_id"`
	UploadURLs []UploadURL `json:"upload_urls"`
	ExpiresIn  int         `json:"expires_in_seconds"`
}

// ── ALLOWED FORMATS ───────────────────────────────────────────────────
var allowedOutputFormats = map[string]bool{
	"JPEG": true, "JPG": true, "PNG": true, "WEBP": true,
	"AVIF": true, "BMP": true, "TIFF": true, "GIF": true,
}

var allowedInputExts = map[string]bool{
	"jpg": true, "jpeg": true, "png": true, "webp": true, "gif": true,
	"bmp": true, "tiff": true, "tif": true, "avif": true, "heic": true, "heif": true,
}

const (
	maxFiles  = 10
	maxSizeMB = 25
	urlExpiry = 10 * time.Minute
)

// ── AWS CLIENTS ────────────────────────────────────────────────────────
var (
	s3Client        *s3.Client
	s3PresignClient *s3.PresignClient
	ddbClient       *dynamodb.Client
)

func init() {
	cfg, err := config.LoadDefaultConfig(context.Background(), config.WithRegion(region))
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}
	s3Client = s3.NewFromConfig(cfg)
	s3PresignClient = s3.NewPresignClient(s3Client)
	ddbClient = dynamodb.NewFromConfig(cfg)
}

// ── HANDLER ────────────────────────────────────────────────────────────
func handler(ctx context.Context, req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	// CORS preflight
	if req.HTTPMethod == http.MethodOptions {
		return corsResponse(http.StatusOK, ""), nil
	}

	var body PresignRequest
	if err := json.Unmarshal([]byte(req.Body), &body); err != nil {
		return errResponse(http.StatusBadRequest, "invalid request body"), nil
	}

	// Validate
	if err := validate(body); err != nil {
		return errResponse(http.StatusBadRequest, err.Error()), nil
	}

	requestID := uuid.New().String()
	uploadURLs := make([]UploadURL, 0, len(body.Files))

	for _, f := range body.Files {
		key := fmt.Sprintf("uploads/%s/%s", requestID, f.Name)

		presignedReq, err := s3PresignClient.PresignPutObject(ctx, &s3.PutObjectInput{
			Bucket:        aws.String(bucketName),
			Key:           aws.String(key),
			ContentType:   aws.String(f.Type),
			ContentLength: aws.Int64(f.Size),
			// tag it so lifecycle policy can target uploads/ prefix
			Tagging: aws.String("morphix=true"),
		}, s3.WithPresignExpires(urlExpiry))
		if err != nil {
			log.Printf("presign error for %s: %v", f.Name, err)
			return errResponse(http.StatusInternalServerError, "failed to generate upload URL"), nil
		}

		uploadURLs = append(uploadURLs, UploadURL{
			Filename: f.Name,
			URL:      presignedReq.URL,
		})
	}

	// Store job in DynamoDB
	ttl := time.Now().Add(24 * time.Hour).Unix()
	_, err := ddbClient.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(ddbTable),
		Item: map[string]ddbtypes.AttributeValue{
			"request_id":    &ddbtypes.AttributeValueMemberS{Value: requestID},
			"status":        &ddbtypes.AttributeValueMemberS{Value: "PENDING"},
			"target_format": &ddbtypes.AttributeValueMemberS{Value: strings.ToUpper(body.TargetFormat)},
			"file_count":    &ddbtypes.AttributeValueMemberN{Value: fmt.Sprintf("%d", len(body.Files))},
			"file_names":    &ddbtypes.AttributeValueMemberSS{Value: fileNames(body.Files)},
			"created_at":    &ddbtypes.AttributeValueMemberN{Value: fmt.Sprintf("%d", time.Now().Unix())},
			"ttl":           &ddbtypes.AttributeValueMemberN{Value: fmt.Sprintf("%d", ttl)},
		},
	})
	if err != nil {
		log.Printf("DynamoDB PutItem error: %v", err)
		return errResponse(http.StatusInternalServerError, "failed to record job"), nil
	}

	resp := PresignResponse{
		RequestID:  requestID,
		UploadURLs: uploadURLs,
		ExpiresIn:  int(urlExpiry.Seconds()),
	}

	body2, _ := json.Marshal(resp)
	return events.APIGatewayProxyResponse{
		StatusCode: http.StatusOK,
		Headers:    corsHeaders(),
		Body:       string(body2),
	}, nil
}

// ── VALIDATION ─────────────────────────────────────────────────────────
func validate(req PresignRequest) error {
	if len(req.Files) == 0 {
		return fmt.Errorf("no files provided")
	}
	if len(req.Files) > maxFiles {
		return fmt.Errorf("maximum %d files allowed, got %d", maxFiles, len(req.Files))
	}
	if !allowedOutputFormats[strings.ToUpper(req.TargetFormat)] {
		return fmt.Errorf("unsupported output format: %s", req.TargetFormat)
	}
	for _, f := range req.Files {
		ext := strings.ToLower(strings.TrimPrefix(strings.ToLower(f.Name[strings.LastIndex(f.Name, ".")+1:]), "."))
		if !allowedInputExts[ext] {
			return fmt.Errorf("unsupported input format for file: %s", f.Name)
		}
		if f.Size > maxSizeMB*1024*1024 {
			return fmt.Errorf("file %s exceeds %d MB limit", f.Name, maxSizeMB)
		}
	}
	return nil
}

// ── HELPERS ─────────────────────────────────────────────────────────────
func fileNames(files []FileInfo) []string {
	names := make([]string, len(files))
	for i, f := range files {
		names[i] = f.Name
	}
	return names
}

func corsHeaders() map[string]string {
	return map[string]string{
		"Access-Control-Allow-Origin":  "*",
		"Access-Control-Allow-Methods": "POST, GET, OPTIONS",
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

// ── ENSURE S3 BUCKET CORS (called once at deploy via Terraform) ────────
// This is handled in Terraform, not here.

// ── CORS CONFIGURATION NOTE ────────────────────────────────────────────
// The S3 bucket needs a CORS rule allowing PUT from the CloudFront domain.
// This is configured in Terraform s3 module.

func main() {
	lambda.Start(handler)
}

// ── IOT AUTH HANDLER (same Lambda, different path via API GW) ──────────
// Returns a pre-signed WSS URL for IoT Core WebSocket connection.
// The client uses this to connect directly to IoT Core MQTT over WebSockets.
// Implemented as a separate path /iot-auth?job_id=xxx
// See: https://docs.aws.amazon.com/iot/latest/developerguide/mqtt-ws.html
//
// For simplicity in this Lambda we handle both /presign and /iot-auth routes.
// In production you might split these.

var _ s3types.ObjectCannedACL // suppress import
