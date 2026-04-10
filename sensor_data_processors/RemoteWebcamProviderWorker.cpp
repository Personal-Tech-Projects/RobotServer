#include "RemoteWebcamProviderWorker.h"
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

    while (running_) {
        ssize_t n =
            recvfrom(sockfd_, buffer, sizeof(buffer), 0, nullptr, nullptr);
        // std::cout << "N: " << n << std::endl;

        if (n > 0) {
            // 2. Check if it's too small for our 10-byte header
            if (n < 10) {
                // Swapped \n for std::endl to fix Docker log buffering
                std::cout << "[RWP ERROR] Packet too small (" << n << " bytes)"
                          << std::endl;
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
    }
}