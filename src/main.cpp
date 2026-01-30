#include <iostream>
#include <filesystem>
#include <nvml.h>

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

  return 0;
}
