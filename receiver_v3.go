package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	defaultPort    = 9999
	headerSize     = 32
	maxPacketSize  = 65535
	timeoutSeconds = 30 // Increased timeout
)

type FileTransfer struct {
	fileID         [16]byte
	fileName       string
	totalBlocks    uint32
	receivedBlocks map[uint32][]byte
	mutex          sync.RWMutex
	lastActivity   time.Time
	file           *os.File
	startTime      time.Time
	packetCount    uint64
	bytesReceived  uint64
	duplicates     uint64
}

func main() {
	port := flag.Int("port", defaultPort, "UDP port to listen on")
	outputDir := flag.String("output", "./received", "Output directory")
	timeout := flag.Int("timeout", timeoutSeconds, "Timeout in seconds")
	verbose := flag.Bool("verbose", false, "Verbose logging")
	flag.Parse()

	// Create output directory
	if err := os.MkdirAll(*outputDir, 0755); err != nil {
		log.Fatalf("Failed to create output directory: %v", err)
	}

	log.Printf("=== UDP File Receiver v3 ===")
	log.Printf("Listening on port: %d", *port)
	log.Printf("Output directory: %s", *outputDir)
	log.Printf("Timeout: %d seconds", *timeout)
	log.Printf("Verbose: %v", *verbose)
	log.Printf("")

	// Create UDP listener
	addr := net.UDPAddr{
		Port: *port,
		IP:   net.ParseIP("0.0.0.0"),
	}
	conn, err := net.ListenUDP("udp", &addr)
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	defer conn.Close()

	// Set read buffer size
	conn.SetReadBuffer(8 * 1024 * 1024) // 8MB buffer

	// Active transfers
	transfers := make(map[[16]byte]*FileTransfer)
	var transfersMutex sync.Mutex

	// Progress ticker
	progressTicker := time.NewTicker(2 * time.Second)
	defer progressTicker.Stop()

	// Cleanup ticker
	cleanupTicker := time.NewTicker(5 * time.Second)
	defer cleanupTicker.Stop()

	// Progress display goroutine
	go func() {
		for range progressTicker.C {
			transfersMutex.Lock()
			for _, transfer := range transfers {
				transfer.mutex.RLock()
				elapsed := time.Since(transfer.startTime)
				received := len(transfer.receivedBlocks)
				total := int(transfer.totalBlocks)
				progress := float64(received) / float64(total) * 100
				throughput := float64(transfer.bytesReceived) / elapsed.Seconds() / 1024 // KB/s
				eta := time.Duration(0)
				if received > 0 {
					remainingBlocks := total - received
					timePerBlock := elapsed / time.Duration(received)
					eta = timePerBlock * time.Duration(remainingBlocks)
				}

				log.Printf("[%x] Progress: %.1f%% | Blocks: %d/%d | Packets: %d | Duplicates: %d | Throughput: %.2f KB/s | ETA: %v",
					transfer.fileID[:4], progress, received, total, transfer.packetCount, transfer.duplicates, throughput, eta.Round(time.Second))
				transfer.mutex.RUnlock()
			}
			transfersMutex.Unlock()
		}
	}()

	// Cleanup goroutine
	go func() {
		for range cleanupTicker.C {
			transfersMutex.Lock()
			for fileID, transfer := range transfers {
				transfer.mutex.RLock()
				idleTime := time.Since(transfer.lastActivity)
				received := len(transfer.receivedBlocks)
				total := int(transfer.totalBlocks)
				transfer.mutex.RUnlock()

				// Check if transfer is complete
				if received == total {
					log.Printf("[%x] Transfer complete! Saving file...", fileID[:4])
					if err := saveFile(transfer, *outputDir); err != nil {
						log.Printf("[%x] Error saving file: %v", fileID[:4], err)
					} else {
						elapsed := time.Since(transfer.startTime)
						throughput := float64(transfer.bytesReceived) / elapsed.Seconds() / 1024
						log.Printf("[%x] === File Saved Successfully ===", fileID[:4])
						log.Printf("[%x] Blocks: %d/%d (100%%)", fileID[:4], received, total)
						log.Printf("[%x] Packets: %d", fileID[:4], transfer.packetCount)
						log.Printf("[%x] Duplicates: %d", fileID[:4], transfer.duplicates)
						log.Printf("[%x] Duration: %v", fileID[:4], elapsed.Round(time.Millisecond))
						log.Printf("[%x] Throughput: %.2f KB/s (%.2f Mbps)", fileID[:4], throughput, throughput*8/1024)
						log.Printf("")
					}
					delete(transfers, fileID)
				} else if idleTime > time.Duration(*timeout)*time.Second {
					// Timeout - but still save partial file
					log.Printf("[%x] === Transfer Timeout ===", fileID[:4])
					log.Printf("[%x] Last activity: %v ago", fileID[:4], idleTime.Round(time.Millisecond))
					log.Printf("[%x] Blocks received: %d/%d (%.1f%%)", fileID[:4], received, total, float64(received)/float64(total)*100)
					log.Printf("[%x] Missing blocks: %d", fileID[:4], total-received)
					log.Printf("[%x] Saving partial file...", fileID[:4])

					if err := saveFile(transfer, *outputDir); err != nil {
						log.Printf("[%x] Error saving partial file: %v", fileID[:4], err)
					} else {
						log.Printf("[%x] Partial file saved (may be incomplete)", fileID[:4])
					}
					log.Printf("")
					delete(transfers, fileID)
				}
			}
			transfersMutex.Unlock()
		}
	}()

	log.Println("Waiting for packets...")
	log.Println("")

	// Main receive loop
	buffer := make([]byte, maxPacketSize)
	for {
		n, _, err := conn.ReadFromUDP(buffer)
		if err != nil {
			log.Printf("Error reading packet: %v", err)
			continue
		}

		if n < headerSize {
			if *verbose {
				log.Printf("Received packet too small: %d bytes", n)
			}
			continue
		}

		// Parse header
		var fileID [16]byte
		copy(fileID[:], buffer[0:16])
		totalBlocks := binary.BigEndian.Uint32(buffer[16:20])
		blockIndex := binary.BigEndian.Uint32(buffer[20:24])
		dataLength := binary.BigEndian.Uint32(buffer[24:28])
		checksum := binary.BigEndian.Uint32(buffer[28:32])

		// Validate packet
		if int(headerSize+dataLength) > n {
			if *verbose {
				log.Printf("Invalid packet: data length mismatch")
			}
			continue
		}

		// Verify checksum
		calcChecksum := uint32(0)
		for i := uint32(0); i < dataLength; i++ {
			calcChecksum += uint32(buffer[headerSize+i])
		}
		if calcChecksum != checksum {
			if *verbose {
				log.Printf("Checksum mismatch: expected %d, got %d", checksum, calcChecksum)
			}
			continue
		}

		// Get or create transfer
		transfersMutex.Lock()
		transfer, exists := transfers[fileID]
		if !exists {
			transfer = &FileTransfer{
				fileID:         fileID,
				totalBlocks:    totalBlocks,
				receivedBlocks: make(map[uint32][]byte),
				startTime:      time.Now(),
				lastActivity:   time.Now(),
			}
			transfers[fileID] = transfer
			log.Printf("[%x] New transfer started: %d blocks expected", fileID[:4], totalBlocks)
		}
		transfersMutex.Unlock()

		// Store block (use memory-efficient approach)
		transfer.mutex.Lock()
		if _, exists := transfer.receivedBlocks[blockIndex]; exists {
			transfer.duplicates++
			if *verbose {
				log.Printf("[%x] Duplicate block %d", fileID[:4], blockIndex)
			}
		} else {
			// Only store unique blocks to save memory
			blockData := make([]byte, dataLength)
			copy(blockData, buffer[headerSize:headerSize+dataLength])
			transfer.receivedBlocks[blockIndex] = blockData
		}
		transfer.packetCount++
		transfer.bytesReceived += uint64(n)
		transfer.lastActivity = time.Now()
		transfer.mutex.Unlock()
	}
}

func saveFile(transfer *FileTransfer, outputDir string) error {
	transfer.mutex.Lock()
	defer transfer.mutex.Unlock()

	// Generate filename
	fileName := fmt.Sprintf("file_%x.bin", transfer.fileID[:8])
	filePath := filepath.Join(outputDir, fileName)

	// Create file
	file, err := os.Create(filePath)
	if err != nil {
		return fmt.Errorf("failed to create file: %v", err)
	}
	defer file.Close()

	// Write blocks in order
	missingBlocks := []uint32{}
	for i := uint32(0); i < transfer.totalBlocks; i++ {
		if blockData, exists := transfer.receivedBlocks[i]; exists {
			if _, err := file.Write(blockData); err != nil {
				return fmt.Errorf("failed to write block %d: %v", i, err)
			}
		} else {
			missingBlocks = append(missingBlocks, i)
			// Write zeros for missing blocks to maintain file structure
			// file.Write(make([]byte, expectedBlockSize))
		}
	}

	if len(missingBlocks) > 0 {
		log.Printf("[%x] Missing blocks: %v (showing first 20)", transfer.fileID[:4], limitSlice(missingBlocks, 20))
		return fmt.Errorf("incomplete file: %d blocks missing", len(missingBlocks))
	}

	log.Printf("[%x] File saved: %s", transfer.fileID[:4], filePath)
	return nil
}

func limitSlice(slice []uint32, limit int) []uint32 {
	if len(slice) <= limit {
		return slice
	}
	return slice[:limit]
}
