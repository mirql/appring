cmake_minimum_required(VERSION 3.21)
project(appring-spike LANGUAGES CXX)
set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
find_package(Qt6 REQUIRED COMPONENTS Gui Qml Quick)
add_executable(appring-spike main.cpp)
target_compile_definitions(appring-spike PRIVATE
  SPIKE_SHARE="../share/appring-spike"
  SPIKE_ICONS="${SPIKE_ICONS}")
target_link_libraries(appring-spike PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick)
install(TARGETS appring-spike RUNTIME DESTINATION bin)
