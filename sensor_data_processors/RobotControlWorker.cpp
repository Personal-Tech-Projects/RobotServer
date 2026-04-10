#include "RobotControlWorker.h"
#include <arpa/inet.h>
#include <chrono>
#include <cstring>
#include <iostream>
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

    int tcp_server_socket = socket(AF_INET, SOCK_STREAM, 0);
    if (tcp_server_socket < 0) {
        std::cerr << "Error creating TCP socket" << std::endl;
        return;
    }

    int opt = 1;
    setsockopt(tcp_server_socket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in tcp_addr;
    memset(&tcp_addr, 0, sizeof(tcp_addr));
    tcp_addr.sin_family = AF_INET;
    tcp_addr.sin_addr.s_addr = INADDR_ANY;
    tcp_addr.sin_port = htons(5005);

    if (bind(tcp_server_socket, (struct sockaddr*)&tcp_addr, sizeof(tcp_addr)) <
        0) {
        std::cerr << "TCP bind failed. Port 5005 might be in use." << std::endl;
        close(tcp_server_socket);
        return;
    }

    listen(tcp_server_socket, 1);
    std::cout << "Waiting for Arduino to connect via TCP on port 5005..."
              << std::endl;

    // The code will completely PAUSE on this next line until the Arduino powers
    // on
    struct sockaddr_in esp_addr;
    socklen_t esp_len = sizeof(esp_addr);
    int esp_client_socket =
        accept(tcp_server_socket, (struct sockaddr*)&esp_addr, &esp_len);

    if (esp_client_socket >= 0) {
        char buffer[1024] = {0};
        int bytes_read = read(esp_client_socket, buffer, sizeof(buffer) - 1);

        if (bytes_read > 0) {
            std::cout << "\n--- Handshake Successful ---" << std::endl;
            std::cout << "Arduino IP address: " << buffer;
            std::cout << "----------------------------\n" << std::endl;
            ARDUINO_IP = std::string(buffer);
        }

        close(esp_client_socket); // Hang up the client connection
    }
    close(tcp_server_socket); // Stop listening on TCP completely

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

    isRunning_ = true;
    while (isRunning_) {
        // std::cout << "RCW while IsRunning Entered" << std::endl;
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
}

void RobotControlWorker::stop() { isRunning_ = false; }

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

void RobotControlWorker::processLLMInput(std::shared_ptr<SensorData> data) {
    // read data, find out which movement to take
    // loop for amount of time to do that movement
    std::cout << "LLM process called" << std::endl;

    int timeToGoHalfFootMs = 940;
    int timeToGo45DegreesMs = 600;
    int sleepTime = 0;

    if (data->llmInput.has_value()) {

        std::cout << "LLMInput has value" << std::endl;

        if (data->llmInput->type == MovementType::Forward) {
            sleepTime = ((data->llmInput->value) / 0.5) * timeToGoHalfFootMs;
            sendUDP("MOTOR, FORWARD");
            // std::this_thread::sleep_for(std::chrono::milliseconds(sleepTime));
            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
            sendUDP("MOTOR, STOP");
        } else if (data->llmInput->type == MovementType::Backward) {
            sleepTime = ((data->llmInput->value) / 0.5) * timeToGoHalfFootMs;
            sendUDP("MOTOR, BACKWARD");
            // std::this_thread::sleep_for(std::chrono::milliseconds(sleepTime));
            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
            sendUDP("MOTOR, STOP");
        } else if (data->llmInput->type == MovementType::Left) {
            sendUDP("MOTOR, LEFT");
            sleepTime = ((data->llmInput->value) / 45) * timeToGo45DegreesMs;
            // std::this_thread::sleep_for(std::chrono::milliseconds(sleepTime));
            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
            sendUDP("MOTOR, STOP");
        } else if (data->llmInput->type == MovementType::Right) {
            sleepTime = ((data->llmInput->value) / 45) * timeToGo45DegreesMs;
            sendUDP("MOTOR, RIGHT");
            // std::this_thread::sleep_for(std::chrono::milliseconds(sleepTime));
            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
            sendUDP("MOTOR, STOP");
        } else if (data->llmInput->type == MovementType::Stop) {
            sendUDP("MOTOR, STOP");
        }
    }
}
// void RobotControlWorker::sendUDP(const char* message) {
//     std::cout << "sendUdp: " << message << std::endl;
//     sendto(arduinoSocket_, message, strlen(message), 0,
//            (struct sockaddr*)&arduinoAddr_, sizeof(arduinoAddr_));
// }

void RobotControlWorker::sendUDP(const char* message) {
    std::cout << "[C++] Attempting to send UDP: " << message << std::endl;

    ssize_t bytes_sent =
        sendto(arduinoSocket_, message, strlen(message), 0,
               (struct sockaddr*)&arduinoAddr_, sizeof(arduinoAddr_));

    if (bytes_sent < 0) {
        perror("[C++] UDP sendto failed"); // This will print the exact OS error
    } else {
        std::cout << "[C++] Successfully sent " << bytes_sent << " bytes to "
                  << ARDUINO_IP << std::endl;
    }
}