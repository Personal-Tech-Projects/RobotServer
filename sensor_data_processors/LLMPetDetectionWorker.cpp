#include "LLMPetDetectionWorker.h"
#include <chrono>
#include <cpr/cpr.h>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <thread>

using json = nlohmann::json;

std::string loadApiKey() {
    std::ifstream file("gemini_api_key.txt");
    if (!file.is_open()) {
        std::cerr << "Could not open gemini_api_key.txt" << std::endl;
        return "";
    }
    std::string key;
    std::getline(file, key); // Safely read just the first line

    // Strip hidden Windows carriage returns (\r) and trailing spaces
    while (!key.empty() &&
           (key.back() == '\r' || key.back() == ' ' || key.back() == '\n')) {
        key.pop_back();
    }

    return key;
}

// Convert raw image bytes to Base64 string for the API
std::string base64_encode(const std::vector<uint8_t>& buf) {
    static const char base64_chars[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string ret;
    int i = 0, j = 0;
    uint8_t char_array_3[3], char_array_4[4];

    for (size_t k = 0; k < buf.size(); k++) {
        char_array_3[i++] = buf[k];
        if (i == 3) {
            char_array_4[0] = (char_array_3[0] & 0xfc) >> 2;
            char_array_4[1] = ((char_array_3[0] & 0x03) << 4) +
                              ((char_array_3[1] & 0xf0) >> 4);
            char_array_4[2] = ((char_array_3[1] & 0x0f) << 2) +
                              ((char_array_3[2] & 0xc0) >> 6);
            char_array_4[3] = char_array_3[2] & 0x3f;
            for (i = 0; (i < 4); i++)
                ret += base64_chars[char_array_4[i]];
            i = 0;
        }
    }
    if (i) {
        for (j = i; j < 3; j++)
            char_array_3[j] = '\0';
        char_array_4[0] = (char_array_3[0] & 0xfc) >> 2;
        char_array_4[1] =
            ((char_array_3[0] & 0x03) << 4) + ((char_array_3[1] & 0xf0) >> 4);
        char_array_4[2] =
            ((char_array_3[1] & 0x0f) << 2) + ((char_array_3[2] & 0xc0) >> 6);
        for (j = 0; (j < i + 1); j++)
            ret += base64_chars[char_array_4[j]];
        while ((i++ < 3))
            ret += '=';
    }
    return ret;
}

LLMPetDetectionWorker::LLMPetDetectionWorker(
    std::shared_ptr<SensorDataDispatcherInterface> dispatcher)
    : dispatcher_(std::move(dispatcher)),
      queue_(folly::ProducerConsumerQueue<std::shared_ptr<SensorData>>(100)) {
    apiKey_ = loadApiKey();
}

void LLMPetDetectionWorker::enqueue(std::shared_ptr<SensorData> data) {
    if (!data->image.has_value()) {
        return;
    }
    queue_.write(data);
}

void LLMPetDetectionWorker::start() {
    isRunning_ = true;
    while (isRunning_) {
        if (!queue_.isEmpty()) {

            std::shared_ptr<SensorData> latestData = nullptr;
            std::shared_ptr<SensorData> tempData;

            // Read every frame currently stuck in the traffic jam.
            // This loop quickly empties the queue and leaves us with only the
            // freshest frame.
            while (queue_.read(tempData)) {
                latestData = tempData;
            }

            // Now, only send that single, freshest frame to Gemini!
            if (latestData) {
                process(latestData);

                // Wait 10 seconds so Google doesn't block us
                std::this_thread::sleep_for(std::chrono::seconds(2));
            }

        } else {
            // CPU SAVER: Don't spin at 100% CPU when the queue is empty
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }
}

void LLMPetDetectionWorker::stop() {
    std::cout << "LLMPetDetectionWorker stopped." << std::endl;
    isRunning_ = false;
}

void LLMPetDetectionWorker::process(std::shared_ptr<SensorData> data) {
    if (!data->image.has_value() || data->image->jpegBuffer.empty()) {
        return;
    }

    // 1. Ask Gemini
    std::optional<Object> detectedPet = askGemini(data->image->jpegBuffer);
    cachedImages_[cachedImagesIndex_] = data;
    ++cachedImagesIndex_;
    cachedImagesIndex_ = cachedImagesIndex_ % 10;

    // 2. If Gemini found something, update the SensorData struct
    if (detectedPet.has_value()) {

        // Initialize the vector if it's currently empty/nullopt
        if (!data->detectedObjects.has_value()) {
            data->detectedObjects = std::vector<int>();
        }

        // Cast the enum to an int and push it to the vector
        data->detectedObjects->push_back(static_cast<int>(detectedPet.value()));
    }
}

std::optional<Object>
LLMPetDetectionWorker::askGemini(const std::vector<uint8_t>& imageBuffer) {
    if (apiKey_.empty())
        return std::nullopt;

    std::string url = "https://generativelanguage.googleapis.com/v1beta/models/"
                      "gemini-2.5-flash:generateContent?key=" +
                      apiKey_;

    json promptParts = json::array();
    promptParts.push_back(
        {{"text",
          "You are the autonomous navigation brain of a physical robot. "
          "You are provided with a sequence of images. The first images "
          "represent your recent movement history in chronological order. "
          "The FINAL image is your CURRENT front-facing view. "
          "Analyze the CURRENT frame. Your goals: "
          "1. Identify if a 'Dog', 'Cat', or 'None' is in view. "
          "2. If a Dog or Cat is in view, you MUST stay in place (set "
          "'movementType' to 'stop' and 'movementValue' to 0.0). "
          "3. Avoid hitting walls, furniture, or obstacles. "
          "4. If no animal is visible, use your visual history to avoid "
          "getting stuck in turning loops, and explore the environment by "
          "moving forward or turning to scan the room. "
          "Determine your next discrete movement. 'movementType' must be one "
          "of: forward, backward, left, right, or stop. "
          "'movementValue' must be a float. You are strictly allowed to use "
          "only the following values: "
          "- For 'forward' or 'backward' (distance in feet): 0.5, 1.0, 1.5, "
          "2.0, 2.5, 3.0, 3.5, 4.0, 4.5, or 5.0. "
          "- For 'left' or 'right' (rotation in degrees): 45.0 or 90.0. "
          "- For 'stop': 0.0."
          "'movementReason' must be a string. Give reasoning behind your "
          "movement choice."}});

    // 3. Loop through history and add them to the payload
    for (const auto& pastData : cachedImages_) {
        if (pastData && pastData->image.has_value() &&
            !pastData->image->jpegBuffer.empty()) {
            std::string base64History =
                base64_encode(pastData->image->jpegBuffer);
            promptParts.push_back(
                {{"inline_data",
                  {{"mime_type", "image/jpeg"}, {"data", base64History}}}});
        }
    }

    // 4. Add the CURRENT image LAST so it matches the prompt's instructions
    std::string base64Current = base64_encode(imageBuffer);
    promptParts.push_back(
        {{"inline_data",
          {{"mime_type", "image/jpeg"}, {"data", base64Current}}}});

    // 5. Assemble the final payload object
    json payload = {
        {"contents", {{{"parts", promptParts}}}},
        {"generationConfig",
         {{"response_mime_type", "application/json"},
          {"response_schema",
           {{"type", "OBJECT"},
            {"properties",
             {{"detectedAnimal",
               {{"type", "STRING"}, {"enum", {"Dog", "Cat", "None"}}}},
              {"movementType",
               {{"type", "STRING"},
                {"enum", {"forward", "backward", "left", "right", "stop"}}}},
              {"movementValue", {{"type", "NUMBER"}}},
              {"movementReason", {{"type", "STRING"}}}}},
            {"required", json::array({"detectedAnimal", "movementType",
                                      "movementValue"})}}}}}};

    // 6. Send Request
    cpr::Response r = cpr::Post(
        cpr::Url{url}, cpr::Header{{"Content-Type", "application/json"}},
        cpr::Body{payload.dump()});

    if (r.status_code == 200) {
        try {
            json apiResponse = json::parse(r.text);
            std::string aiJsonString =
                apiResponse["candidates"][0]["content"]["parts"][0]["text"]
                    .get<std::string>();
            json parsedData = json::parse(aiJsonString);

            // 2. Extract all three fields from the JSON
            std::string detectedText =
                parsedData["detectedAnimal"].get<std::string>();
            std::string movementType =
                parsedData["movementType"].get<std::string>();
            float movementValue = parsedData["movementValue"].get<float>();
            std::string movementReason =
                parsedData["movementReason"].get<std::string>();

            std::cout << "Movement Type: " << movementType << std::endl;
            std::cout << "Movement Value: " << movementValue << std::endl;
            std::cout << "Movement Reason: " << movementReason << std::endl;

            MovementType moveEnum = MovementType::Stop;
            if (movementType == "forward") {
                std::cout << "forward" << std::endl;
                moveEnum = MovementType::Forward;
            } else if (movementType == "backward") {
                std::cout << "backward" << std::endl;
                moveEnum = MovementType::Backward;
            } else if (movementType == "left") {
                std::cout << "left" << std::endl;
                moveEnum = MovementType::Left;
            } else if (movementType == "right") {
                std::cout << "right" << std::endl;
                moveEnum = MovementType::Right;
            } else if (movementType == "stop") {
                std::cout << "stop" << std::endl;
                moveEnum = MovementType::Stop;
            }

            LLMInputData llmCommand;
            llmCommand.type = moveEnum;
            llmCommand.value = movementValue;

            auto sensorData = std::make_shared<SensorData>();
            sensorData->llmInput = llmCommand;

            if (detectedText == "Dog") {
                sensorData->detectedObjects =
                    std::vector<int>{static_cast<int>(Object::Dog)};
            } else if (detectedText == "Cat") {
                sensorData->detectedObjects =
                    std::vector<int>{static_cast<int>(Object::Cat)};
            }

            dispatcher_->enqueueData(sensorData);

        } catch (const std::exception& e) {
            std::cerr << "[LLM ERROR] Parsing failed: " << e.what()
                      << std::endl;
            return std::nullopt;
        }
    } else {
        std::cerr << "[LLM ERROR] HTTP " << r.status_code << std::endl;
        std::cerr << "Google says: " << r.text << std::endl;
        return std::nullopt;
    }

    return std::nullopt;
}