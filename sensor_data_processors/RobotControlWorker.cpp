#include "RobotControlWorker.h"
#include <arpa/inet.h>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

std::string ARDUINO_IP;
const int ARDUINO_PORT = 4210;

RobotControlWorker::RobotControlWorker()
    : queue_(folly::ProducerConsumerQueue<std::shared_ptr<SensorData>>(100)) {}

void RobotControlWorker::enqueue(std::shared_ptr<SensorData> data) {
    if (!data->userInput.has_value() && !data->llmInput.has_value()) {
        return;
    }
    queue_.write(data);
}

void RobotControlWorker::start() {

    listenSocket_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listenSocket_ < 0) {
        std::cerr << "Error creating TCP socket" << std::endl;
        return;
    }

    int opt = 1;
    setsockopt(listenSocket_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in tcp_addr;
    memset(&tcp_addr, 0, sizeof(tcp_addr));
    tcp_addr.sin_family = AF_INET;
    tcp_addr.sin_addr.s_addr = INADDR_ANY;
    tcp_addr.sin_port = htons(5005);

    if (bind(listenSocket_, (struct sockaddr*)&tcp_addr, sizeof(tcp_addr)) < 0) {
        std::cerr << "TCP bind failed. Port 5005 might be in use." << std::endl;
        close(listenSocket_);
        listenSocket_ = -1;
        return;
    }

    listen(listenSocket_, 8);
    std::cout << "Waiting for Arduino to connect via TCP on port 5005..."
              << std::endl;

    // Time out accept() every second so stop() can break us out of this loop.
    // Accepted client sockets inherit this, which also stops a connection that
    // opens but never sends from stalling us.
    struct timeval acceptTimeout;
    acceptTimeout.tv_sec = 1;
    acceptTimeout.tv_usec = 0;
    setsockopt(listenSocket_, SOL_SOCKET, SO_RCVTIMEO, &acceptTimeout,
               sizeof(acceptTimeout));

    // Keep accepting until a connection actually delivers the Arduino's IP.
    // The ESP32's keepalive opens a connection every second; if one of those
    // arrives first we must hang up on it and keep listening, otherwise the
    // ping silently consumes the handshake and ARDUINO_IP is never set.
    isRunning_ = true;
    while (isRunning_ && ARDUINO_IP.empty()) {
        struct sockaddr_in esp_addr;
        socklen_t esp_len = sizeof(esp_addr);
        int esp_client_socket =
            accept(listenSocket_, (struct sockaddr*)&esp_addr, &esp_len);

        if (esp_client_socket < 0) {
            continue; // accept timed out - keep waiting
        }

        char buffer[1024] = {0};
        int bytes_read = read(esp_client_socket, buffer, sizeof(buffer) - 1);
        close(esp_client_socket); // Hang up the client connection

        if (bytes_read <= 0) {
            continue; // keepalive ping, not a handshake
        }

        std::cout << "\n--- Handshake Successful ---" << std::endl;
        std::cout << "Arduino IP address: " << buffer;
        std::cout << "----------------------------\n" << std::endl;
        ARDUINO_IP = std::string(buffer);
    }

    if (ARDUINO_IP.empty()) {
        close(listenSocket_); // stopped before the Arduino ever handshook
        listenSocket_ = -1;
        return;
    }

    // NOTE: listenSocket_ is deliberately left open. Closing it here is what
    // made the handshake a one-shot: every later reconnect hit a dead port.
    // From here the main loop drains it without blocking.
    fcntl(listenSocket_, F_SETFL, O_NONBLOCK);

    // UDP Call

    arduinoSocket_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (arduinoSocket_ < 0) {
        std::cerr << "Error creating UDP socket" << std::endl;
        return;
    }
    arduinoAddr_.sin_family = AF_INET;
    arduinoAddr_.sin_port = htons(ARDUINO_PORT);
    if (inet_pton(AF_INET, ARDUINO_IP.c_str(), &arduinoAddr_.sin_addr) <= 0) {
        std::cerr << "Invalid Arduino IP address format: " << ARDUINO_IP
                  << std::endl;
        return;
    }
    // inet_pton(AF_INET, ARDUINO_IP, &arduinoAddr_.sin_addr);

    while (isRunning_) {
        // std::cout << "RCW while IsRunning Entered" << std::endl;
        drainKeepalives();
        if (!queue_.isEmpty()) {
            std::cout << "queue not empty" << std::endl;
            std::shared_ptr<SensorData> sensorData;
            if (queue_.read(sensorData)) {
                process(sensorData);
            } else {
            }
        }
    }

    // Cleanup
    close(arduinoSocket_);
    if (listenSocket_ >= 0) {
        close(listenSocket_);
        listenSocket_ = -1;
    }
}

void RobotControlWorker::stop() { isRunning_ = false; }

// The ESP32 opens a fresh connection every second as its liveness check. Those
// have to be accepted and hung up on, or they queue up in the listen backlog
// until it overflows and the ESP32 starts seeing its own pings fail.
void RobotControlWorker::drainKeepalives() {
    while (true) {
        struct sockaddr_in esp_addr;
        socklen_t esp_len = sizeof(esp_addr);
        int esp_client_socket =
            accept(listenSocket_, (struct sockaddr*)&esp_addr, &esp_len);

        if (esp_client_socket < 0) {
            return; // nothing pending
        }

        char buffer[1024] = {0};
        int bytes_read = read(esp_client_socket, buffer, sizeof(buffer) - 1);
        close(esp_client_socket);

        if (bytes_read <= 0) {
            continue;
        }

        // Pings carry the IP too, so a reboot onto a new DHCP lease re-registers
        // itself instead of leaving us sending to the stale address.
        std::string reportedIp(buffer);
        if (reportedIp != ARDUINO_IP) {
            struct in_addr parsed;
            if (inet_pton(AF_INET, reportedIp.c_str(), &parsed) > 0) {
                ARDUINO_IP = reportedIp;
                arduinoAddr_.sin_addr = parsed;
                std::cout << "Arduino IP updated to " << ARDUINO_IP << std::endl;
            }
        }
    }
}

void RobotControlWorker::process(std::shared_ptr<SensorData> data) {

    std::cout << "RCW process" << std::endl;

    if (data->userInput.has_value()) {
        processUserInput(data);
    }

    if (data->llmInput.has_value()) {
        std::cout << "hasvalue" << std::endl;
        processLLMInput(data);
    }
}

void RobotControlWorker::processUserInput(std::shared_ptr<SensorData> data) {

    bool forwardKeyPressed = data->userInput.value().forward;
    bool backwardKeyPressed = data->userInput.value().backward;
    bool leftKeyPressed = data->userInput.value().left;
    bool rightKeyPressed = data->userInput.value().right;

    // Note: Your comment says "Only send packet if the state CHANGED"
    // but this logic still fires every single frame the key is held!
    if (forwardKeyPressed) {
        sendUDP("MOTOR, FORWARD");
        std::cout << "Motor forward sent" << std::endl;
    } else if (backwardKeyPressed) {
        sendUDP("MOTOR, BACKWARD");
        std::cout << "Motor backward sent" << std::endl;
    } else if (leftKeyPressed) {
        sendUDP("MOTOR, LEFT");
        std::cout << "Motor left sent" << std::endl;
    } else if (rightKeyPressed) {
        sendUDP("MOTOR, RIGHT");
        std::cout << "Motor right sent" << std::endl;
    } else {
        sendUDP("MOTOR, STOP");
        std::cout << "Motor stop sent" << std::endl;
    }
}

// Added Thread Sleeping for proper motor timing

void RobotControlWorker::processLLMInput(std::shared_ptr<SensorData> data) {
    std::cout << "LLM process called" << std::endl;

    // CALIBRATION VALUES: Change these to match robot's speed
    int timeToGoHalfFootMs = 940;
    int timeToGo45DegreesMs = 600;
    int sleepTime = 0;

    // if (data->llmInput.has_value()) {
    //     std::cout << "LLMInput has value" << std::endl;

    //     if (data->llmInput->type == MovementType::Forward) {
    //         sleepTime = ((data->llmInput->value) / 0.5) * timeToGoHalfFootMs;
    //         sendUDP("MOTOR, FORWARD");
    //         std::this_thread::sleep_for(
    //             std::chrono::milliseconds(sleepTime)); // WAITS HERE
    //         sendUDP("MOTOR, STOP");

    //     } else if (data->llmInput->type == MovementType::Backward) {
    //         sleepTime = ((data->llmInput->value) / 0.5) * timeToGoHalfFootMs;
    //         sendUDP("MOTOR, BACKWARD");
    //         std::this_thread::sleep_for(
    //             std::chrono::milliseconds(sleepTime)); // WAITS HERE
    //         sendUDP("MOTOR, STOP");

    //     } else if (data->llmInput->type == MovementType::Left) {
    //         sleepTime = ((data->llmInput->value) / 45.0) *
    //         timeToGo45DegreesMs; sendUDP("MOTOR, LEFT");
    //         std::this_thread::sleep_for(
    //             std::chrono::milliseconds(sleepTime)); // WAITS HERE
    //         sendUDP("MOTOR, STOP");

    //     } else if (data->llmInput->type == MovementType::Right) {
    //         sleepTime = ((data->llmInput->value) / 45.0) *
    //         timeToGo45DegreesMs; sendUDP("MOTOR, RIGHT");
    //         std::this_thread::sleep_for(
    //             std::chrono::milliseconds(sleepTime)); // WAITS HERE
    //         sendUDP("MOTOR, STOP");

    //     } else if (data->llmInput->type == MovementType::Stop) {
    //         sendUDP("MOTOR, STOP");
    //     }
    // }
}

void RobotControlWorker::sendUDP(const char* message) {
    std::cout << "[C++] Attempting to send UDP: " << message << std::endl;

    ssize_t bytes_sent =
        sendto(arduinoSocket_, message, strlen(message), 0,
               (struct sockaddr*)&arduinoAddr_, sizeof(arduinoAddr_));

    if (bytes_sent < 0) {
        perror(
            "[C++] UDP send to failed"); // This will print the exact OS error
    } else {
        std::cout << "[C++] Successfully sent " << bytes_sent << " bytes to "
                  << ARDUINO_IP << std::endl;
    }
}