#include "SDLWorker.h"
#include "SensorDataWorkerInterface.h"
#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h>
#include <iostream>
#include <thread>

#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

SDLWorker::SDLWorker(std::shared_ptr<SensorDataDispatcherInterface> dispatcher)
    : dispatcher_(std::move(dispatcher)),
      queue_(folly::ProducerConsumerQueue<std::shared_ptr<SensorData>>(100)) {}

void SDLWorker::process(std::shared_ptr<SensorData> data) {}

void SDLWorker::enqueue(std::shared_ptr<SensorData> data) {
    if (!data->image.has_value()) {
        return;
    }
    queue_.write(data);
}

void SDLWorker::start() {

    // 1. Initialize SDL
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std::cerr << "SDL could not initialize! SDL_Error: " << SDL_GetError()
                  << std::endl;
    }

    int imgFlags = IMG_INIT_JPG;
    if (!(IMG_Init(imgFlags) & imgFlags)) {
        std::cerr << "SDL_image could not initialize! SDL_image Error: "
                  << IMG_GetError() << std::endl;
    }

    // 2. Create a window (Required to capture keyboard events)
    SDL_Window* window = SDL_CreateWindow(
        "Robot Controller (click here)", SDL_WINDOWPOS_UNDEFINED,
        SDL_WINDOWPOS_UNDEFINED, 640, 480, SDL_WINDOW_SHOWN);

    if (window == nullptr) {
        std::cerr << "Window could not be created! SDL_Error: "
                  << SDL_GetError() << std::endl;
    }

    //  Test renderer for the window
    SDL_Renderer* renderer =
        SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (renderer == nullptr) {
        std::cerr << "Renderer could not be created! SDL_Error: "
                  << SDL_GetError() << std::endl;
        isRunning = false;
        return;
    }

    // 3. Main Loop Flag
    SDL_Event event;

    std::cout << "Controller started. Press W, A, S, D to drive. Close window "
                 "to quit."
              << std::endl;

    UserInputData inputState;
    auto sendInput = [&]() {
        auto inputData = std::make_shared<SensorData>();
        inputData->userInput = inputState;
        dispatcher_->enqueueData(inputData);
    };

    isRunning = true;

    // bool wasLedOn = false;

    latestData_ = std::make_shared<SensorData>();

    // 4. The Event Loop
    while (isRunning) {
        // ==========================================
        // PHASE 1: INPUT (Process all pending events)
        // ==========================================
        while (SDL_PollEvent(&event) != 0) {
            // Handle Key Pressed Down
            if (event.type == SDL_KEYDOWN) {
                if (event.key.repeat == 0) {
                    switch (event.key.keysym.sym) {
                    case SDLK_w:
                        inputState.forward = true;
                        sendInput();
                        break;
                    case SDLK_a:
                        inputState.left = true;
                        sendInput();
                        break;
                    case SDLK_s:
                        inputState.backward = true;
                        sendInput();
                        break;
                    case SDLK_d:
                        inputState.right = true;
                        sendInput();
                        break;
                    case SDLK_ESCAPE:
                        isRunning = false;
                        break;
                    }
                }
            }
            // Handle Key Released
            else if (event.type == SDL_KEYUP) {
                switch (event.key.keysym.sym) {
                case SDLK_w:
                    inputState.forward = false;
                    sendInput();
                    break;
                case SDLK_a:
                    inputState.left = false;
                    sendInput();
                    break;
                case SDLK_s:
                    inputState.backward = false;
                    sendInput();
                    break;
                case SDLK_d:
                    inputState.right = false;
                    sendInput();
                    break;
                }
            }
            // Optional: Handle user clicking the 'X' on the window
            else if (event.type == SDL_QUIT) {
                isRunning = false;
            }
        } // <--- IMPORTANT: The event loop MUST close here!

        // ==========================================
        // PHASE 3: RENDER (Draw the current frame)
        // ==========================================
        // SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        // SDL_RenderClear(renderer);

        std::shared_ptr<SensorData> currentData;
        {
            if (!queue_.isEmpty()) {
                if (queue_.read(currentData)) {
                    latestData_ = currentData;
                }
            } else {
                currentData = latestData_;
            }

            if (currentData && currentData->image.has_value() &&
                !currentData->image->jpegBuffer.empty()) {

                SDL_RWops* rw =
                    SDL_RWFromConstMem(currentData->image->jpegBuffer.data(),
                                       currentData->image->jpegBuffer.size());

                if (rw != nullptr) {
                    SDL_Surface* surface = IMG_Load_RW(rw, 1);

                    if (surface != nullptr) {
                        SDL_Texture* frameTexture =
                            SDL_CreateTextureFromSurface(renderer, surface);

                        if (frameTexture != nullptr) {
                            SDL_RenderCopy(renderer, frameTexture, NULL, NULL);
                            SDL_DestroyTexture(frameTexture);
                            // currentData->image->jpegBuffer.clear();
                        } else {
                            // ---------------------------------------------------------
                            // LOG 4: Texture Creation Error
                            // ---------------------------------------------------------
                            std::cerr
                                << "[SDL ERROR] Failed to create texture: "
                                << SDL_GetError() << "\n";
                        }
                        SDL_FreeSurface(surface);
                    } else {
                        // ---------------------------------------------------------
                        // LOG 5: JPEG Decoding Error
                        // ---------------------------------------------------------
                        std::cerr
                            << "[SDL ERROR] IMG_Load_RW failed to decode JPEG: "
                            << IMG_GetError() << "\n";
                    }
                } else {
                    std::cerr << "[SDL ERROR] SDL_RWFromConstMem failed.\n";
                }
            }

            SDL_RenderPresent(renderer);

            // ==========================================
            // PHASE 4: WAIT (Control frame rate)
            // ==========================================
            SDL_Delay(16); // roughly 60 FPS
        }
    }

    // Cleanup
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
}
void SDLWorker::stop() { isRunning = false; }
