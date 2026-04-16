package main

import (
	"crypto/md5"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	defaultPacketSize = 1400 // Safe UDP payload size (< MTU 1500)
	headerSize        = 32   // Fixed header size
	maxRetransmit     = 3    // Number of times to send each block
)

// Packet structure:
// [0-15]  File ID (MD5 prefix, 16 bytes)
// [16-19] Total blocks (uint32)
// [20-23] Block index (uint32)
// [24-27] Data length (uint32)
// [28-31] CRC32 checksum (uint32)
// [32+]   Data

type PacketHeader struct {
	FileID      [16]byte
	TotalBlocks uint32
	BlockIndex  uint32
	DataLength  uint32
	Checksum    uint32
}

func main() {
	target := flag.String("target", "localhost:9999", "Target address (host:port)")
	filePath := flag.String("file", "", "File to send")
	packetSize := flag.Int("packet-size", defaultPacketSize, "UDP packet data size")
	retransmit := flag.Int("retransmit", maxRetransmit, "Number of times to send each block")
	rateLimit := flag.Int("rate", 0, "Rate limit in KB/s (0 = unlimited)")
	flag.Parse()

	if *filePath == "" {
		log.Fatal("Please specify a file to send with -file")
	}

	// Open file
	file, err := os.Open(*filePath)
	if err != nil {
		log.Fatalf("Failed to open file: %v", err)
	}
	defer file.Close()

	// Get file info
	fileInfo, err := file.Stat()
	if err != nil {
		log.Fatalf("Failed to stat file: %v", err)
	}
	fileSize := fileInfo.Size()
	fileName := filepath.Base(*filePath)

	// Calculate file ID (MD5 of filename + size)
	hasher := md5.New()
	hasher.Write([]byte(fileName))
	binary.Write(hasher, binary.BigEndian, fileSize)
	fileID := hasher.Sum(nil)[:16]

	// Calculate total blocks
	dataSize := *packetSize - headerSize
	totalBlocks := uint32((fileSize + int64(dataSize) - 1) / int64(dataSize))

	log.Printf("=== UDP File Sender v3 ===")
	log.Printf("File: %s", fileName)
	log.Printf("Size: %s (%.2f MB)", formatBytes(fileSize), float64(fileSize)/1024/1024)
	log.Printf("File ID: %x", fileID)
	log.Printf("Packet size: %d bytes (data: %d bytes)", *packetSize, dataSize)
	log.Printf("Total blocks: %d", totalBlocks)
	log.Printf("Retransmit: %d times per block", *retransmit)
	log.Printf("Target: %s", *target)
	if *rateLimit > 0 {
		log.Printf("Rate limit: %d KB/s", *rateLimit)
	}
	log.Printf("")

	// Resolve address
	addr, err := net.ResolveUDPAddr("udp", *target)
	if err != nil {
		log.Fatalf("Failed to resolve address: %v", err)
	}

	// Create UDP connection
	conn, err := net.DialUDP("udp", nil, addr)
	if err != nil {
		log.Fatalf("Failed to create UDP connection: %v", err)
	}
	defer conn.Close()

	// Send file
	startTime := time.Now()
	totalPackets := uint64(0)
	totalBytes := uint64(0)

	// Rate limiting
	var rateLimiter <-chan time.Time
	if *rateLimit > 0 {
		bytesPerSecond := *rateLimit * 1024
		packetsPerSecond := bytesPerSecond / *packetSize
		if packetsPerSecond < 1 {
			packetsPerSecond = 1
		}
		interval := time.Second / time.Duration(packetsPerSecond)
		rateLimiter = time.Tick(interval)
	}

	// Reusable buffer to reduce allocations
	packet := make([]byte, *packetSize)
	copy(packet[0:16], fileID)
	binary.BigEndian.PutUint32(packet[16:20], totalBlocks)

	// Progress tracking
	lastProgress := time.Now()
	progressInterval := 2 * time.Second

	for blockIndex := uint32(0); blockIndex < totalBlocks; blockIndex++ {
		// Seek to block position (for retransmission)
		offset := int64(blockIndex) * int64(dataSize)
		_, err := file.Seek(offset, 0)
		if err != nil {
			log.Fatalf("Failed to seek file: %v", err)
		}

		// Read block data
		n, err := io.ReadFull(file, packet[headerSize:])
		if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
			log.Fatalf("Failed to read file: %v", err)
		}

		// Prepare header
		binary.BigEndian.PutUint32(packet[20:24], blockIndex)
		binary.BigEndian.PutUint32(packet[24:28], uint32(n))

		// Calculate checksum (simple sum for speed)
		checksum := uint32(0)
		for i := 0; i < n; i++ {
			checksum += uint32(packet[headerSize+i])
		}
		binary.BigEndian.PutUint32(packet[28:32], checksum)

		// Send packet multiple times
		packetLen := headerSize + n
		for i := 0; i < *retransmit; i++ {
			if rateLimiter != nil {
				<-rateLimiter
			}

			_, err = conn.Write(packet[:packetLen])
			if err != nil {
				log.Printf("Warning: Failed to send packet: %v", err)
				continue
			}

			totalPackets++
			totalBytes += uint64(packetLen)
		}

		// Show progress
		if time.Since(lastProgress) >= progressInterval {
			elapsed := time.Since(startTime)
			throughput := float64(totalBytes) / elapsed.Seconds() / 1024 // KB/s
			progress := float64(blockIndex+1) / float64(totalBlocks) * 100
			log.Printf("Progress: %.1f%% | Block %d/%d | Packets: %d | Throughput: %.2f KB/s",
				progress, blockIndex+1, totalBlocks, totalPackets, throughput)
			lastProgress = time.Now()
		}
	}

	duration := time.Since(startTime)
	throughput := float64(totalBytes) / duration.Seconds() / 1024

	log.Printf("")
	log.Printf("=== Transmission Complete ===")
	log.Printf("Blocks sent: %d", totalBlocks)
	log.Printf("Packets sent: %d (x%d retransmit)", totalPackets, *retransmit)
	log.Printf("Total bytes: %s", formatBytes(int64(totalBytes)))
	log.Printf("Duration: %v", duration)
	log.Printf("Throughput: %.2f KB/s (%.2f Mbps)", throughput, throughput*8/1024)
}

func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.2f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}
