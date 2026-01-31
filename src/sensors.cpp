#include "sensors.hpp"
#include <fstream>
#include <iostream>

SysfsSensor::SysfsSensor(std::string name, std::filesystem::path path)
  : name_(name), path_(path) {}

  double SysfsSensor::read_temp() const {
    std::ifstream file(path_);
    if (!file.is_open()) {
      return -1.0; //return errorcode
    }

    long val;
    file >> val;
    return val / 1000.0;
  }
