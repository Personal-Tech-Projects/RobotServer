#include "LLMPetDetectionWorker.h"
#include "RemoteWebcamProviderWorker.h"
#include "RobotControlWorker.h"
#include "SDLWorker.h"
#include "SensorDataDispatcher.h"
#include "WorkerManager.h"
#include <fcntl.h>
#include <iostream>
#include <sys/file.h>
#include <unistd.h>

int main() {
    int lockFd = open("/tmp/robot_server.lock", O_CREAT | O_RDWR, 0644);
    if (lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) < 0) {
        if (lockFd >= 0)
            close(lockFd);
        std::cerr << "ROBOTSERVER is already running." << std::endl;
        return 1;
    }
    if (ftruncate(lockFd, 0) < 0) {
        std::cerr << "Unable to update ROBOTSERVER lock file." << std::endl;
        close(lockFd);
        return 1;
    }
    dprintf(lockFd, "%d\n", getpid());

    std::cout << "Hello, Robot Server!" << std::endl;
    std::vector<std::shared_ptr<SensorDataWorkerInterface>> processors;
    auto dispatcher = std::make_shared<SensorDataDispatcher>(processors);

    std::vector<std::shared_ptr<WorkerInterface>> workers;
    std::vector<std::shared_ptr<WorkerInterface>> asyncWorkers;

    auto sdlWorker = std::make_shared<SDLWorker>(dispatcher);
    auto remoteWebcamProviderWorker =
        std::make_shared<RemoteWebcamProviderWorker>(dispatcher);
    auto llmWorker = std::make_shared<LLMPetDetectionWorker>(dispatcher);
    auto robotControlWorker = std::make_shared<RobotControlWorker>();

    dispatcher->addProcessor(sdlWorker);
    dispatcher->addProcessor(llmWorker);
    dispatcher->addProcessor(robotControlWorker);

    asyncWorkers.push_back(remoteWebcamProviderWorker);
    asyncWorkers.push_back(sdlWorker);
    asyncWorkers.push_back(llmWorker);
    asyncWorkers.push_back(robotControlWorker);

    WorkerManager workerManager(dispatcher, workers, asyncWorkers);
    workerManager.start();

    char input;
    std::cin >> input;
    while (input != 'q') {
        std::cin >> input;
    }

    workerManager.stop();

    std::cout << "Bye robot Server!" << std::endl;

    // TODO: write code that blocks and waits for input to end the program
    // when key is pressed, call workerManager.stop

    close(lockFd);
    return 0;
}
