{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.imacFanControl;

  # Хелпер для обработки null в опциях
  overrideCpu = if cfg.sensorOverrides.cpu != null then cfg.sensorOverrides.cpu else "";
  overrideGpu = if cfg.sensorOverrides.gpu != null then cfg.sensorOverrides.gpu else "";
  overrideCase = if cfg.sensorOverrides.case != null then cfg.sensorOverrides.case else "";

  script = pkgs.writeShellScriptBin "imac-fan-control" ''
    set -u

    APPLESMC="/sys/devices/platform/applesmc.768"
    STATE_DIR="/run/imac-fan-control"
    FAIL_LIMIT=3
    
    # Внедряем значения из Nix
    CONF_OVERRIDE_CPU="${overrideCpu}"
    CONF_OVERRIDE_GPU="${overrideGpu}"
    CONF_OVERRIDE_CASE="${overrideCase}"

    mkdir -p "$STATE_DIR"

    log() { echo "[imac-fan] $*"; }

    cleanup() {
      log "Cleaning up..."
      for f in ${concatStringsSep " " (map (f: f.fan) (attrValues cfg.fans))}; do
        if [ -w "$APPLESMC/''${f}_manual" ]; then
           echo 0 > "$APPLESMC/''${f}_manual" 2>/dev/null || true
        fi
      done
      exit 0
    }
    trap cleanup EXIT INT TERM

    # ---------- helpers (Pure Bash) ----------

    abs() { echo $(( $1 < 0 ? -$1 : $1 )); }

    calc_speed() {
      local t=$1 min_t=$2 max_t=$3 min_r=$4 max_r=$5
      if [ "$min_t" -eq "$max_t" ]; then echo "$max_r"; return; fi # Div/0 guard
      
      if [ "$t" -le "$min_t" ]; then echo "$min_r"
      elif [ "$t" -ge "$max_t" ]; then echo "$max_r"
      else
        echo $(( (t - min_t) * (max_r - min_r) / (max_t - min_t) + min_r ))
      fi
    }

    read_temp_file() {
      local val
      if [ -r "$1" ]; then
        read -r val < "$1" 2>/dev/null || return 1
        echo $((val / 1000))
      else
        return 1
      fi
    }

    # ---------- Initialization & Discovery ----------

    log "Initializing..."

    # --- 1. CPU ---
    if [ -n "$CONF_OVERRIDE_CPU" ]; then
      log "CPU: Using override -> $CONF_OVERRIDE_CPU"
      CPU_SENSOR="$CONF_OVERRIDE_CPU"
    else
      log "CPU: Auto-detecting coretemp..."
      CPU_SENSOR=""
      for d in /sys/class/hwmon/hwmon*; do
        if [ -r "$d/name" ]; then
          read -r name < "$d/name"
          if [ "$name" = "coretemp" ]; then
             CPU_SENSOR="$d/temp1_input"
             break
          fi
        fi
      done
    fi

    # --- 2. CASE ---
    if [ -n "$CONF_OVERRIDE_CASE" ]; then
      log "CASE: Using override -> $CONF_OVERRIDE_CASE"
      CASE_SENSOR="$CONF_OVERRIDE_CASE"
    else
      log "CASE: Auto-detecting AppleSMC sensor..."
      CASE_SENSOR=""
      CASE_LABEL=$(grep -l -E 'TA0P|TC0P|TB0T' $APPLESMC/temp*_label 2>/dev/null | head -n1)
      if [ -n "$CASE_LABEL" ]; then
        CASE_SENSOR="''${CASE_LABEL%_label}_input"
      fi
    fi

    # --- 3. GPU Strategy ---
    # GPU может читаться через файл (override/amd) или через команду (nvidia-smi)
    GPU_STRATEGY="none"
    
    if [ -n "$CONF_OVERRIDE_GPU" ]; then
      log "GPU: Using override file -> $CONF_OVERRIDE_GPU"
      GPU_SENSOR="$CONF_OVERRIDE_GPU"
      GPU_STRATEGY="file"
    elif [ -x "${cfg.nvidiaSmi}" ]; then
      log "GPU: Using nvidia-smi binary"
      GPU_STRATEGY="nvidia"
    else
      log "GPU: No strategy found (will allow running without GPU temp)"
    fi

    # Validation
    if [ -z "$CPU_SENSOR" ] && [ -z "$CASE_SENSOR" ]; then
       log "CRITICAL: No CPU or Case sensors found. Exiting."
       exit 1
    fi

    # ---------- Hysteresis ----------
    state_file() { echo "$STATE_DIR/$1.last"; }
    
    should_update() {
      local key="$1" temp="$2" up="$3" down="$4"
      local last file
      file=$(state_file "$key")
      
      if [ -r "$file" ]; then read -r last < "$file"; else last=""; fi
      if [ -z "$last" ]; then echo "$temp" > "$file"; return 0; fi

      local delta=$(( temp - last ))
      if [ "$delta" -ge 0 ]; then [ "$delta" -ge "$up" ] || return 1
      else [ "$(abs "$delta")" -ge "$down" ] || return 1; fi

      echo "$temp" > "$file"
      return 0
    }

    # ---------- Main Loop ----------
    fail_count=0
    log "Starting loop..."

    while true; do
      ok=1
      
      # Read CPU
      if [ -n "$CPU_SENSOR" ]; then
        CPU_T=$(read_temp_file "$CPU_SENSOR") || ok=0
      else
        CPU_T=0
      fi

      # Read Case
      if [ -n "$CASE_SENSOR" ]; then
        CASE_T=$(read_temp_file "$CASE_SENSOR") || ok=0
      else
        CASE_T=0
      fi

      # Read GPU
      if [ "$GPU_STRATEGY" = "file" ]; then
         GPU_T=$(read_temp_file "$GPU_SENSOR") || ok=0
      elif [ "$GPU_STRATEGY" = "nvidia" ]; then
         GPU_T=$(${cfg.nvidiaSmi} --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null) || ok=0
         if [ -z "$GPU_T" ]; then ok=0; fi
      else
         GPU_T=0
      fi

      # Error Handling
      if [ "$ok" -eq 0 ]; then
        fail_count=$((fail_count + 1))
        if [ "$fail_count" -ge "$FAIL_LIMIT" ]; then
          log "Sensor failure. Resetting to AUTO."
          cleanup # This calls exit, systemd restarts it
        fi
        sleep ${toString cfg.interval}
        continue
      fi
      fail_count=0

      # Apply Fans
      ${concatStringsSep "\n" (mapAttrsToList (name: f: ''
        FAN_ID="${f.fan}"
        ROLE="${f.role}"
        
        if [ "$ROLE" = "gpu" ]; then T="$GPU_T"
        elif [ "$ROLE" = "cpu" ]; then T="$CPU_T"
        else T="$CASE_T"; fi

        if [ "$T" -ge ${toString cfg.panicTemp} ]; then
          echo 1 > "$APPLESMC/''${FAN_ID}_manual"
          echo "${toString f.maxRpm}" > "$APPLESMC/''${FAN_ID}_output"
        else
          RPM=$(calc_speed "$T" ${toString f.minTemp} ${toString f.maxTemp} ${toString f.minRpm} ${toString f.maxRpm})
          if should_update "${name}" "$T" ${toString f.hysteresisUp} ${toString f.hysteresisDown}; then
            echo 1 > "$APPLESMC/''${FAN_ID}_manual"
            echo "$RPM" > "$APPLESMC/''${FAN_ID}_output"
          fi
        fi
      '') cfg.fans)}

      sleep ${toString cfg.interval}
    done
  '';
in
{
  options.services.imacFanControl = {
    enable = mkEnableOption "iMac advanced fan control";

    interval = mkOption { type = types.int; default = 5; };
    panicTemp = mkOption { type = types.int; default = 90; };
    
    nvidiaSmi = mkOption {
      type = types.path;
      default = "${config.hardware.nvidia.package}/bin/nvidia-smi";
    };

    sensorOverrides = mkOption {
      description = "Override automatic sensor detection with absolute paths to sysfs files.";
      default = {};
      type = types.submodule {
        options = {
          cpu = mkOption { 
            type = types.nullOr types.str; 
            default = null; 
            description = "Path to CPU temp input (e.g. /sys/class/hwmon/hwmon2/temp1_input)";
          };
          gpu = mkOption { 
            type = types.nullOr types.str; 
            default = null; 
            description = "Path to GPU temp input. If set, ignores nvidia-smi.";
          };
          case = mkOption { 
            type = types.nullOr types.str; 
            default = null; 
            description = "Path to Case/Ambient temp input.";
          };
        };
      };
    };

    fans = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          fan = mkOption { type = types.str; };
          role = mkOption { type = types.enum [ "cpu" "gpu" "case" ]; };
          minTemp = mkOption { type = types.int; };
          maxTemp = mkOption { type = types.int; };
          minRpm  = mkOption { type = types.int; };
          maxRpm  = mkOption { type = types.int; };
          hysteresisUp = mkOption { type = types.int; default = 2; };
          hysteresisDown = mkOption { type = types.int; default = 4; };
        };
      });
    };
  };

  config = mkIf cfg.enable {
    systemd.services.imac-fan-control = {
      description = "iMac Fan Control";
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ coreutils gnugrep gnused ];
      serviceConfig = {
        ExecStart = "${script}/bin/imac-fan-control";
        Restart = "always";
        RestartSec = 5;
        User = "root";
        ProtectSystem = "full";
        PrivateTmp = true;
      };
    };
  };
}
