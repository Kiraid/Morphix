package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddbtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/aws/aws-sdk-go-v2/service/iotdataplane"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// ── ENV ───────────────────────────────────────────────────────────────
var (
	bucketName  = os.Getenv("S3_BUCKET")
	ddbTable    = os.Getenv("DDB_TABLE")
	iotEndpoint = os.Getenv("IOT_ENDPOINT") // e.g. https://xxxx.iot.us-east-1.amazonaws.com
	region      = os.Getenv("AWS_REGION")
)

// ── AWS CLIENTS ────────────────────────────────────────────────────────
var (
	s3Client        *s3.Client
	s3PresignClient *s3.PresignClient
	ddbClient       *dynamodb.Client
	iotClient       *iotdataplane.Client
)

func init() {
	cfg, err := config.LoadDefaultConfig(context.Background(), config.WithRegion(region))
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}
	s3Client = s3.NewFromConfig(cfg)
	s3PresignClient = s3.NewPresignClient(s3Client)
	ddbClient = dynamodb.NewFromConfig(cfg)
	iotClient = iotdataplane.NewFromConfig(cfg, func(o *iotdataplane.Options) {
		o.BaseEndpoint = aws.String(iotEndpoint)
	})
}


type ConversionResult struct {
	Filename string 
	OutName  string 
	Data     []byte
	Err      error
}

type IoTMessage struct {
	Status      string `json:"status"`
	RequestID   string `json:"request_id"`
	DownloadURL string `json:"download_url,omitempty"`
	FileCount   int    `json:"file_count,omitempty"`
	Message     string `json:"message,omitempty"`
}


func handler(ctx context.Context, sqsEvent events.SQSEvent) error {
	for _, record := range sqsEvent.Records {
		if err := processRecord(ctx, record); err != nil {
			log.Printf("ERROR processing record %s: %v", record.MessageId, err)
			return err
		}
	}
	return nil
}

func processRecord(ctx context.Context, record events.SQSMessage) error {
	var s3Notification struct {
		Records []struct {
			S3 struct {
				Object struct {
					Key string `json:"key"`
				} `json:"object"`
			} `json:"s3"`
		} `json:"Records"`
	}

	if err := json.Unmarshal([]byte(record.Body), &s3Notification); err != nil {
		return fmt.Errorf("failed to parse S3 notification: %w", err)
	}

	if len(s3Notification.Records) == 0 {
		log.Println("no S3 records in SQS message, skipping")
		return nil
	}


	key := s3Notification.Records[0].S3.Object.Key
	parts := strings.Split(key, "/")
	if len(parts) < 3 || parts[0] != "uploads" {
		log.Printf("unexpected S3 key format: %s", key)
		return nil
	}
	requestID := parts[1]

	// Load job from DynamoDB
	job, err := loadJob(ctx, requestID)
	if err != nil {
		return fmt.Errorf("failed to load job %s: %w", requestID, err)
	}

	// Guard: avoid duplicate SQS deliveries 
	if job["status"] == "PROCESSING" || job["status"] == "DONE" || job["status"] == "ERROR" {
		log.Printf("job %s already in state %s, skipping", requestID, job["status"])
		return nil
	}

	targetFormat := job["target_format"]
	fileCount := int(mustParseInt(job["file_count"]))
	fileNames := strings.Split(job["file_names"], ",")

	// Check all files are present in S3 before processing.
	present, err := countFilesInPrefix(ctx, fmt.Sprintf("uploads/%s/", requestID))
	if err != nil {
		return fmt.Errorf("failed to list S3 prefix: %w", err)
	}
	if present < fileCount {
		log.Printf("job %s: expected %d files, found %d — will retry", requestID, fileCount, present)
		return fmt.Errorf("incomplete upload: %d/%d files present", present, fileCount)
	}

	// Change the job status to PROCESSING
	if err := updateJobStatus(ctx, requestID, "PROCESSING", ""); err != nil {
		return err
	}
	publishIoT(ctx, requestID, IoTMessage{Status: "PROCESSING", RequestID: requestID})

	// Convert all images in parallel goroutines
	results := convertImages(ctx, requestID, fileNames, targetFormat)
	for _, r := range results {
		if r.Err != nil {
			log.Printf("conversion error for %s: %v", r.Filename, r.Err)
			updateJobStatus(ctx, requestID, "ERROR", r.Err.Error())
			publishIoT(ctx, requestID, IoTMessage{
				Status:    "ERROR",
				RequestID: requestID,
				Message:   fmt.Sprintf("Failed to convert %s", r.Filename),
			})
			return r.Err
		}
	}

	// SINGLE FILE: upload directly
	if fileCount == 1 {
		r := results[0]
		outputKey := fmt.Sprintf("converted/%s/%s", requestID, r.OutName)

		if err := uploadToS3(ctx, outputKey, r.Data, getContentType(r.OutName)); err != nil {
			updateJobStatus(ctx, requestID, "ERROR", err.Error())
			return fmt.Errorf("failed to upload converted file: %w", err)
		}

		downloadURL, err := presignDownloadURL(ctx, outputKey, 24*time.Hour)
		if err != nil {
			return fmt.Errorf("failed to presign download URL: %w", err)
		}

		updateJobStatus(ctx, requestID, "DONE", downloadURL)
		publishIoT(ctx, requestID, IoTMessage{
			Status:      "DONE",
			RequestID:   requestID,
			DownloadURL: downloadURL,
			FileCount:   1,
		})

		log.Printf("job %s completed (single file): %s", requestID, outputKey)
		return nil
	}

	// MULTIPLE FILES: build ZIP 
	publishIoT(ctx, requestID, IoTMessage{Status: "ZIPPING", RequestID: requestID})

	zipData, err := buildZip(results)
	if err != nil {
		updateJobStatus(ctx, requestID, "ERROR", err.Error())
		return fmt.Errorf("failed to build ZIP: %w", err)
	}

	zipKey := fmt.Sprintf("converted/%s/images_%s.zip", requestID, strings.ToLower(targetFormat))
	if err := uploadToS3(ctx, zipKey, zipData, "application/zip"); err != nil {
		updateJobStatus(ctx, requestID, "ERROR", err.Error())
		return fmt.Errorf("failed to upload ZIP: %w", err)
	}

	downloadURL, err := presignDownloadURL(ctx, zipKey, 24*time.Hour)
	if err != nil {
		return fmt.Errorf("failed to presign download URL: %w", err)
	}

	updateJobStatus(ctx, requestID, "DONE", downloadURL)
	publishIoT(ctx, requestID, IoTMessage{
		Status:      "DONE",
		RequestID:   requestID,
		DownloadURL: downloadURL,
		FileCount:   len(results),
	})

	log.Printf("job %s completed: %d files → %s", requestID, len(results), zipKey)
	return nil
}


func convertImages(ctx context.Context, requestID string, fileNames []string, targetFormat string) []ConversionResult {
	results := make([]ConversionResult, len(fileNames))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4) 
	for i, name := range fileNames {
		wg.Add(1)
		go func(idx int, filename string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			key := fmt.Sprintf("uploads/%s/%s", requestID, filename)
			data, err := downloadFromS3(ctx, key)
			if err != nil {
				results[idx] = ConversionResult{Filename: filename, Err: fmt.Errorf("download failed: %w", err)}
				return
			}

			converted, outName, err := convertWithFFmpeg(data, filename, targetFormat)
			if err != nil {
				results[idx] = ConversionResult{Filename: filename, Err: fmt.Errorf("conversion failed: %w", err)}
				return
			}

			results[idx] = ConversionResult{Filename: filename, OutName: outName, Data: converted}
		}(i, name)
	}

	wg.Wait()
	return results
}

// convertWithFFmpeg shells out to ffmpeg to convert image data.
func convertWithFFmpeg(data []byte, originalName, targetFormat string) ([]byte, string, error) {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(originalName), "."))
	if ext == "heic" || ext == "heif" {
		ext = "heic"
	}

	outExt := strings.ToLower(targetFormat)
	if outExt == "jpeg" {
		outExt = "jpg"
	}

	base := strings.TrimSuffix(originalName, filepath.Ext(originalName))
	outName := fmt.Sprintf("%s.%s", base, outExt)

	if outExt == "avif" {
		return convertAVIFViaTemp(data, originalName, outName)
	}

	args := buildFFmpegArgs(ext, outExt)
	cmd := exec.Command("ffmpeg", args...)
	cmd.Stdin = bytes.NewReader(data)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, "", fmt.Errorf("ffmpeg error: %v — stderr: %s", err, stderr.String())
	}

	return stdout.Bytes(), outName, nil
}


func convertAVIFViaTemp(data []byte, originalName, outName string) ([]byte, string, error) {
	uid := fmt.Sprintf("%d", time.Now().UnixNano())
	inPath := fmt.Sprintf("/tmp/in_%s_%s", uid, originalName)
	outPath := fmt.Sprintf("/tmp/out_%s_%s", uid, outName)
	defer os.Remove(inPath)
	defer os.Remove(outPath)

	if err := os.WriteFile(inPath, data, 0600); err != nil {
		return nil, "", fmt.Errorf("failed to write temp input: %w", err)
	}

	cmd := exec.Command("ffmpeg",
		"-hide_banner", "-loglevel", "error",
		"-i", inPath,
		"-c:v", "libaom-av1", "-crf", "30", "-b:v", "0",
		"-f", "avif", outPath,
	)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, "", fmt.Errorf("ffmpeg avif error: %v — stderr: %s", err, stderr.String())
	}

	converted, err := os.ReadFile(outPath)
	if err != nil {
		return nil, "", fmt.Errorf("failed to read avif output: %w", err)
	}

	return converted, outName, nil
}

func buildFFmpegArgs(inExt, outExt string) []string {
	base := []string{
		"-hide_banner", "-loglevel", "error",
		"-i", "pipe:0",
	}

	switch outExt {
	case "jpg", "jpeg":
		base = append(base, "-q:v", "2")
	case "webp":
		base = append(base, "-q:v", "80")
	case "png":
		base = append(base, "-compression_level", "6")
	case "gif":
		base = append(base, "-vf", "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse")
	}

	base = append(base, "-f", ffmpegFormat(outExt), "pipe:1")
	return base
}

func ffmpegFormat(ext string) string {
	m := map[string]string{
		"jpg": "mjpeg", "jpeg": "mjpeg",
		"png": "apng", "webp": "webp",
		"gif": "gif", "bmp": "bmp",
		"tiff": "tiff", "tif": "tiff",
	}
	if f, ok := m[ext]; ok {
		return f
	}
	return ext
}

func getContentType(filename string) string {
	m := map[string]string{
		"jpg":  "image/jpeg",
		"jpeg": "image/jpeg",
		"png":  "image/png",
		"gif":  "image/gif",
		"webp": "image/webp",
		"avif": "image/avif",
		"bmp":  "image/bmp",
		"tiff": "image/tiff",
		"tif":  "image/tiff",
	}
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(filename), "."))
	if ct, ok := m[ext]; ok {
		return ct
	}
	return "application/octet-stream"
}


func buildZip(results []ConversionResult) ([]byte, error) {
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)

	for _, r := range results {
		f, err := w.Create(r.OutName) // OutName has the correct converted extension
		if err != nil {
			return nil, fmt.Errorf("zip create %s: %w", r.OutName, err)
		}
		if _, err := f.Write(r.Data); err != nil {
			return nil, fmt.Errorf("zip write %s: %w", r.OutName, err)
		}
	}

	if err := w.Close(); err != nil {
		return nil, fmt.Errorf("zip close: %w", err)
	}
	return buf.Bytes(), nil
}

// s3 helpers
func downloadFromS3(ctx context.Context, key string) ([]byte, error) {
	out, err := s3Client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String(key),
	})
	if err != nil {
		return nil, err
	}
	defer out.Body.Close()
	return io.ReadAll(out.Body)
}

func uploadToS3(ctx context.Context, key string, data []byte, contentType string) error {
	_, err := s3Client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(bucketName),
		Key:         aws.String(key),
		Body:        bytes.NewReader(data),
		ContentType: aws.String(contentType),
	})
	return err
}

func presignDownloadURL(ctx context.Context, key string, expiry time.Duration) (string, error) {
	req, err := s3PresignClient.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucketName),
		Key:    aws.String(key),
	}, s3.WithPresignExpires(expiry))
	if err != nil {
		return "", err
	}
	return req.URL, nil
}

func countFilesInPrefix(ctx context.Context, prefix string) (int, error) {
	out, err := s3Client.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
		Bucket: aws.String(bucketName),
		Prefix: aws.String(prefix),
	})
	if err != nil {
		return 0, err
	}
	return int(out.KeyCount), nil
}

// DYNAMODB HELPERS 
func loadJob(ctx context.Context, requestID string) (map[string]string, error) {
	out, err := ddbClient.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(ddbTable),
		Key: map[string]ddbtypes.AttributeValue{
			"request_id": &ddbtypes.AttributeValueMemberS{Value: requestID},
		},
	})
	if err != nil {
		return nil, err
	}

	result := make(map[string]string)
	for k, v := range out.Item {
		switch attr := v.(type) {
		case *ddbtypes.AttributeValueMemberS:
			result[k] = attr.Value
		case *ddbtypes.AttributeValueMemberN:
			result[k] = attr.Value
		case *ddbtypes.AttributeValueMemberSS:
			result[k] = strings.Join(attr.Value, ",")
		}
	}
	return result, nil
}

func updateJobStatus(ctx context.Context, requestID, status, extra string) error {
	updateExpr := "SET #s = :s, updated_at = :ts"
	exprAttrNames := map[string]string{"#s": "status"}
	exprAttrVals := map[string]ddbtypes.AttributeValue{
		":s":  &ddbtypes.AttributeValueMemberS{Value: status},
		":ts": &ddbtypes.AttributeValueMemberN{Value: fmt.Sprintf("%d", time.Now().Unix())},
	}

	if status == "DONE" && extra != "" {
		updateExpr += ", download_url = :url"
		exprAttrVals[":url"] = &ddbtypes.AttributeValueMemberS{Value: extra}
	} else if status == "ERROR" && extra != "" {
		updateExpr += ", error_message = :err"
		exprAttrVals[":err"] = &ddbtypes.AttributeValueMemberS{Value: extra}
	}

	_, err := ddbClient.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:                 aws.String(ddbTable),
		Key:                       map[string]ddbtypes.AttributeValue{"request_id": &ddbtypes.AttributeValueMemberS{Value: requestID}},
		UpdateExpression:          aws.String(updateExpr),
		ExpressionAttributeNames:  exprAttrNames,
		ExpressionAttributeValues: exprAttrVals,
	})
	return err
}

// IOT CORE 
func publishIoT(ctx context.Context, requestID string, msg IoTMessage) {
	payload, err := json.Marshal(msg)
	if err != nil {
		log.Printf("failed to marshal IoT message: %v", err)
		return
	}

	topic := fmt.Sprintf("morphix/jobs/%s", requestID)
	_, err = iotClient.Publish(ctx, &iotdataplane.PublishInput{
		Topic:   aws.String(topic),
		Payload: payload,
		Qos:     aws.Int32(0),
	})
	if err != nil {
		log.Printf("failed to publish IoT message: %v", err)
	}
}

// UTILS 
func mustParseInt(s string) int64 {
	var n int64
	fmt.Sscanf(s, "%d", &n)
	return n
}

func main() {
	lambda.Start(handler)
}