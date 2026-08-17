# Autonomous Pet-Tracking Robot (RobotServer)
A custom-built, autonomous robot designed to track and monitor pets using computer vision, LLM reasoning, and LiDAR SLAM navigation.  
## The Problem and Goal:
**The Limitation:** Most pet cameras just sit in one spot. They don't move and typically don't alert you when something important is happening; they just stream video. 

**The Goal:** I wanted to create something more active. A dynamic system capable of real-time identification, tracking, and spatial navigation within a home environment. 

## How it Evolved:

This project evolved significantly as I tested different methods for vision and autonomous navigation. 

<ins>**Phase 1: Manual Telemetry & Video Streaming**</ins>

The initial build was a user-controlled rover. 
- Hardware: An ESP32 controlling the motors and a Raspberry Pi handling the camera.
- Software: A custom C++ server utilizing SDL. The Pi streamed live JPEG frames over UDP to the SDL window, which simultaneously captured keyboard inputs and sent UDP drive commands back to the ESP32.

The Raspberry Pi streamed JPEG frames over UDP, and the SDL window let me both see the feed and control the robot with my keyboard. It worked, but everything was manual.

<ins>**Phase 2: Local Computer Vision**</ins> 

To automate pet tracking, I experimented with local computer-vision models on the incoming UDP stream.

**Challenge:** Local model accuracy was inconsistent for reliable pet detection on the fly. 

**<ins>Phase 3: LLM Vision & "The Brain"**</ins>

I pivoted to sending the UDP frames to a Vision-Language Model (LLM) with a custom prompt.

**Result:** Detection accuracy and speed significantly increased.

**Next Step:** I attempted to make the LLM the "brain" of the robot, feeding it frames and having it send drive commands to the ESP32.

**Challenge:** The LLM lacked spatial memory, resulting in erratic movements. I engineered a manual memory system by passing a vector of historical frames and printing the LLM's reasoning to debug its logic, but it still lacked true spatial awareness.

**<ins>Phase 4: LiDAR & ROS2 SLAM (Current State)**</ins> 

To solve the spatial awareness issue and achieve precise movement without motor encoders, I am currently integrating LiDAR alongside an advanced ROS2 navigation stack.

- Current Architecture: Moved navigation into a containerized ROS2 environment. I am also flashing the ESP32 with micro-ROS to allow it to communicate seamlessly as a native node within the ROS2 ecosystem.
- Odometry & Routing: Because the motors lack physical encoders, I am utilizing an RS20 LiDAR within the ROS2 container to generate highly accurate LiDAR-based odometry.
- Goal: Generate an accurate SLAM (Simultaneous Localization and Mapping) map using the LiDAR and feed this data to the LLM. Once the LLM executes precise, logic-driven target selection on the map, Nav2 computes the optimal, collision-free path. The micro-ROS ESP32 then controls the motors directly, using the real-time RS20 odometry feedback to drive accurately to the LLM's selected coordinates.

## System Architecture & Tech Stack

- Core Server: C++
- Containers: Docker/DevContainers
- Microcontrollers: ESP32 (micro-ROS, Direct Motor Control), Raspberry Pi (Sensors/Camera)
- Networking: UDP, micro-ROS middleware
- Navigation & Mapping: ROS2, Nav2, RS20 LiDAR, SLAM, LiDAR Odometry
- Vision & AI: OpenCV and Large Language Models (LLMs)

