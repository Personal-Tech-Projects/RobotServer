#include "RemoteWebcamProviderWorker.h"
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <iostream>
#include <map>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

RemoteWebcamProviderWorker::RemoteWebcamProviderWorker(
    std::shared_ptr<SensorDataDispatcher> dispatcher)
    : dispatcher_(dispatcher), sockfd_(-1), running_(false) {}

RemoteWebcamProviderWorker::~RemoteWebcamProviderWorker() { stop(); }

void RemoteWebcamProviderWorker::start() {
    std::cout << "RWP start" << std::endl;
    running_ = true;

    sockfd_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd_ < 0) {
        perror("Socket creation failed");
        return;
    }

    std::cout << "RWP socket creation did not fail" << std::endl;

    int reuse = 1;
    setsockopt(sockfd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    // Set a timeout so recvfrom doesn't block forever, allowing clean shutdown
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 100000; // 100ms
    setsockopt(sockfd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in servaddr;
    std::memset(&servaddr, 0, sizeof(servaddr));
    servaddr.sin_family = AF_INET;
    servaddr.sin_addr.s_addr = INADDR_ANY;
    servaddr.sin_port = htons(5005);

    if (bind(sockfd_, (const struct sockaddr*)&servaddr, sizeof(servaddr)) <
        0) {
        perror("Bind failed");
        close(sockfd_);
        return;
    }
    std::cout << "RWP bind creation did not fail" << std::endl;

    std::cout << "RemoteWebcamProviderWorker started on port 5005..."
              << std::endl;

    receiveLoop();
}

void RemoteWebcamProviderWorker::stop() {
    if (!running_)
        return;
    running_ = false;

    if (sockfd_ != -1) {
        close(sockfd_);
        sockfd_ = -1;
    }
    std::cout << "RemoteWebcamProviderWorker stopped." << std::endl;
}

void RemoteWebcamProviderWorker::receiveLoop() {
    // 1. INCREASE BUFFER SIZE to safely hold the 1410 byte packets
    std::cout << "RWP recieve loop called" << std::endl;

    uint8_t buffer[2048];

    // Disabled by default. Set to 1000 for one-second stability diagnostics.
    const char* diagnosticIntervalText =
        std::getenv("ROBOTSERVER_WEBCAM_DIAG_INTERVAL_MS");
    long diagnosticIntervalMs = 0;
    if (diagnosticIntervalText != nullptr) {
        char* end = nullptr;
        const long parsed = std::strtol(diagnosticIntervalText, &end, 10);
        if (end != diagnosticIntervalText && *end == '\0' && parsed > 0) {
            diagnosticIntervalMs = parsed;
        } else {
            std::cerr
                << "[RWP-DIAG] Ignoring invalid "
                   "ROBOTSERVER_WEBCAM_DIAG_INTERVAL_MS='"
                << diagnosticIntervalText << "'" << std::endl;
        }
    }

    const bool diagnosticsEnabled = diagnosticIntervalMs > 0;
    const auto diagnosticInterval =
        std::chrono::milliseconds(diagnosticIntervalMs);

    const char* diagnosticMaxReportsText =
        std::getenv("ROBOTSERVER_WEBCAM_DIAG_MAX_REPORTS");
    long diagnosticMaxReports = 0;
    if (diagnosticMaxReportsText != nullptr) {
        char* end = nullptr;
        const long parsed = std::strtol(diagnosticMaxReportsText, &end, 10);
        if (end != diagnosticMaxReportsText && *end == '\0' && parsed >= 0) {
            diagnosticMaxReports = parsed;
        } else {
            std::cerr
                << "[RWP-DIAG] Ignoring invalid "
                   "ROBOTSERVER_WEBCAM_DIAG_MAX_REPORTS='"
                << diagnosticMaxReportsText << "'" << std::endl;
        }
    }

    uint64_t diagnosticReportsEmitted = 0;
    const auto diagnosticsActive = [&]() {
        return diagnosticsEnabled &&
               (diagnosticMaxReports == 0 ||
                diagnosticReportsEmitted <
                    static_cast<uint64_t>(diagnosticMaxReports));
    };
    if (diagnosticsEnabled) {
        std::cout << "[RWP-DIAG] enabled interval_ms="
                  << diagnosticIntervalMs << " max_reports="
                  << (diagnosticMaxReports > 0
                          ? std::to_string(diagnosticMaxReports)
                          : std::string("unlimited"))
                  << std::endl;
    }

    uint64_t receivedDatagramsTotal = 0;
    uint64_t receivedDatagramsInterval = 0;
    uint64_t completeChunkSetsTotal = 0;
    uint64_t completeChunkSetsInterval = 0;
    uint64_t smallPacketsTotal = 0;
    uint64_t smallPacketsAtLastLog = 0;
    uint32_t latestCompleteChunkSetFrame = 0;
    bool hasCompleteChunkSet = false;
    bool hasLoggedSmallPacket = false;
    auto lastCompleteChunkSetAt = std::chrono::steady_clock::now();
    auto lastDiagnosticAt = std::chrono::steady_clock::now();
    auto lastSmallPacketLogAt = std::chrono::steady_clock::now();

    while (running_) {
        ssize_t n =
            recvfrom(sockfd_, buffer, sizeof(buffer), 0, nullptr, nullptr);
        // std::cout << "N: " << n << std::endl;

        if (n > 0) {
            if (diagnosticsActive()) {
                ++receivedDatagramsTotal;
                ++receivedDatagramsInterval;
            }

            // 2. Check if it's too small for our 10-byte header
            if (n < 10) {
                ++smallPacketsTotal;
                const auto now = std::chrono::steady_clock::now();
                if (!hasLoggedSmallPacket ||
                    now - lastSmallPacketLogAt >= std::chrono::seconds(10)) {
                    std::cerr
                        << "[RWP ERROR] Dropped short webcam packet bytes=" << n
                        << " since_last_log="
                        << smallPacketsTotal - smallPacketsAtLastLog
                        << " total=" << smallPacketsTotal << std::endl;
                    hasLoggedSmallPacket = true;
                    smallPacketsAtLastLog = smallPacketsTotal;
                    lastSmallPacketLogAt = now;
                }
                continue; // Skip the rest of the loop and wait for the next
                          // packet
            }

            // 3. Safely unpack the binary header (matching Python's '<IHHH')
            uint32_t frame_id;
            uint16_t total_chunks;
            uint16_t chunk_index;
            uint16_t chunk_size;

            std::memcpy(&frame_id, buffer, sizeof(frame_id));
            std::memcpy(&total_chunks, buffer + 4, sizeof(total_chunks));
            std::memcpy(&chunk_index, buffer + 6, sizeof(chunk_index));
            std::memcpy(&chunk_size, buffer + 8, sizeof(chunk_size));

            // Swapped \n for std::endl to fix Docker log buffering
            // std::cout << "[RWP] Got frame " << frame_id << " | chunk "
            //<< chunk_index << "/" << total_chunks
            //<< " | size: " << chunk_size << " bytes" << std::endl;

            // 4. Extract the payload (the actual JPEG bytes)
            std::vector<uint8_t> payload(buffer + 10, buffer + 10 + chunk_size);

            // 5. Store the chunk in our map
            frameBuffers_[frame_id][chunk_index] = payload;

            // 6. Check if we have received all chunks for this frame
            if (frameBuffers_[frame_id].size() == total_chunks) {

                // This means every sender-declared chunk is present. JPEG
                // decoding and rendering happen later in SDLWorker.
                if (diagnosticsActive()) {
                    ++completeChunkSetsTotal;
                    ++completeChunkSetsInterval;
                    latestCompleteChunkSetFrame = frame_id;
                    hasCompleteChunkSet = true;
                    lastCompleteChunkSetAt =
                        std::chrono::steady_clock::now();
                }

                // Swapped \n for std::endl to fix Docker log buffering
                // std::cout << "[RWP SUCCESS] Frame " << frame_id << " fully
                // assembled! Sending to SDL." << std::endl;

                // Assemble the full JPEG
                auto data = std::make_shared<SensorData>();
                data->image = ImageData();

                std::time_t currentTime = std::time(nullptr);
                localtime_r(&currentTime, &data->image->timestamp);

                for (uint16_t i = 0; i < total_chunks; ++i) {
                    data->image->jpegBuffer.insert(
                        data->image->jpegBuffer.end(),
                        frameBuffers_[frame_id][i].begin(),
                        frameBuffers_[frame_id][i].end());
                }

                // Send to SDL Worker
                dispatcher_->enqueueData(data);

                // Clean up old frames to prevent memory leaks!
                // We erase this frame, and any older frames that were
                // incomplete
                for (auto it = frameBuffers_.begin();
                     it != frameBuffers_.end();) {
                    if (it->first <= frame_id) {
                        it = frameBuffers_.erase(it);
                    } else {
                        ++it;
                    }
                }
            }
        }

        const auto now = std::chrono::steady_clock::now();
        const auto diagnosticElapsed =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                now - lastDiagnosticAt);
        if (diagnosticsActive() && diagnosticElapsed >= diagnosticInterval) {
            const double seconds = diagnosticElapsed.count() / 1000.0;
            const long long chunkSetAgeMs =
                hasCompleteChunkSet
                ? std::chrono::duration_cast<std::chrono::milliseconds>(
                      now - lastCompleteChunkSetAt)
                      .count()
                : -1;
            std::cout << "[RWP-DIAG] received_datagrams_per_s="
                      << static_cast<double>(receivedDatagramsInterval) /
                             seconds
                      << " complete_chunk_sets_per_s="
                      << static_cast<double>(completeChunkSetsInterval) /
                             seconds
                      << " received_datagrams=" << receivedDatagramsTotal
                      << " complete_chunk_sets=" << completeChunkSetsTotal
                      << " small_packets=" << smallPacketsTotal
                      << " latest_chunk_set_frame="
                      << (hasCompleteChunkSet
                              ? std::to_string(latestCompleteChunkSetFrame)
                              : std::string("none"))
                      << " chunk_set_age_ms=" << chunkSetAgeMs
                      << " pending_frames=" << frameBuffers_.size()
                      << std::endl;
            receivedDatagramsInterval = 0;
            completeChunkSetsInterval = 0;
            lastDiagnosticAt = now;
            ++diagnosticReportsEmitted;
            if (!diagnosticsActive()) {
                std::cout << "[RWP-DIAG] report_limit_reached="
                          << diagnosticReportsEmitted << std::endl;
            }
        }
    }
}
