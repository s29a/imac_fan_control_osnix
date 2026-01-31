#include <iostream>
#include <filesystem>
#include <nvml.h>
#include "sensors.hpp"

namespace fs = std::filesystem;

int main() {
  std::cout << "--- iMac Fan Control (C++ Rewrite) ---" << std::endl;

  fs::path smc_path = "/sys/devices/platform/applesmc.768";
  if (fs::exists(smc_path)) {
    std::cout << "[Ok] AppleSMC found at: " << smc_path << std::endl;
  } else {
    std::cerr << "[ERROR] AppleSMC not found!" << std::endl;
  }

  nvmlReturn_t result = nvmlInit();
  if (result == NVML_SUCCESS) {
    std::cout << "[Ok] NVML Initialized." << std::endl;
    nvmlShutdown();
  } else {
    std::cerr << "[WARN] NVML failed:" << nvmlErrorString(result) << std::endl;
  }

  SysfsSensor cpu_temp("CPU", "/sys/class/hwmon/hwmon1/temp1_input");

  std::cout << "Starting sensor monitor..." << std::endl;

  for(int i = 0; i < 5; ++i) {
    double t = cpu_temp.read_temp();
    std::cout << "Current " << cpu_temp.get_name() << " temp:" << t << "°C" << std::endl;
    std::this_thread::sleep_for(std::chrono::seconds(1));
  }

  return 0;
}
