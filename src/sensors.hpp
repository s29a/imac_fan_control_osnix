#pragma once

#include <string>
#include <filesystem>
#include <thread>

class Sensor {
  public:
    virtual ~Sensor() = default;
    virtual double read_temp() const = 0;
    virtual std::string get_name() const = 0;
};

class SysfsSensor : public Sensor {
  public:
    SysfsSensor(std::string name, std::filesystem::path path);
    double read_temp() const override;
    std::string get_name() const override { return name_;}

  private:
    std::string name_;
    std::filesystem::path path_;
};
