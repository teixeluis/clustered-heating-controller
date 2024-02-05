import mqtt
import json
import math

target_temp = 19

last_heat_req_id = 0
last_heat_req_time = 0
last_heat_req_local_time = 0
last_heat_req_state = 0 # 0 = Reserve, 1 = Commit

last_chill_req_id = 0
last_chill_req_time = 0 
last_chill_req_local_time = 0
last_chill_req_state = 0 # 0 = Reserve, 1 = Commit

current_power = 0
remaining_power = 0
power_report_time = 0

curr_state = 0 # 0 = Idle, 1 = Grace Heat, 2 = Heat, 3 = Heating, 4 = Chill

REPORT_PERIOD = 5
WAIT_PERIOD = 10
GRACE_HEAT_PERIOD = 60000
HEATER_POWER = 2000

def temperature_mode()
    tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FE20DF"}')
end

def door_open()
    tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FE7887"}')
end

def toggle_heat_mode()
    tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FE807F"}')
end

def toggle_flap()
    tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FE40BF"}')
end

def set_timer(hours)
    for i:0..hours
        tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FEC03F"}')
    end
end

def reset_temperature()
    for i:0..27
        tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FE10EF"}')
    end
end

def set_new_temperature(temp)
    temperature_mode()
    reset_temperature()
    for i:0..temp-19
        tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FEA05F"}')
    end
end

def toggle_power()
    tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FE48B7"}')
end

def set_heater_state(state)
    tasmota.cmd('Power1 ' + str(state))
end

def start_heat(cmd, idx, payload, payload_json)
    #var temperature = 22
    #var duration = 1
    
    # parse payload
    #if payload_json != nil && payload_json.find("Temperature") != nil && payload_json.find("Duration")  != nil
    #    temperature = int(payload_json.find("Temperature"))
    #    duration = int(payload_json.find("Duration"))
    #end
    
    if ! tasmota.get_switches()[0]
        tasmota.set_timer(0, /->toggle_power())
    else
        # Cycle the power to make sure in the next step we set to the intended heat level:
        tasmota.set_timer(0, /->toggle_power())
        tasmota.set_timer(50, /->toggle_power())
    end

    # Set to full power:
    tasmota.set_timer(100, /->toggle_heat_mode())
    tasmota.set_timer(200, /->toggle_heat_mode())

    #tasmota.set_timer(500, /->set_new_temperature(temperature))
    tasmota.set_timer(300, /->set_heater_state(1))

    #tasmota.set_timer(2500, /->set_timer(duration))
    
    tasmota.resp_cmnd_done()
end

def stop_heat()
    tasmota.set_timer(0,/->set_heater_state(0))

    # Only turn off if the power is on:
    if tasmota.get_switches()[0]
        tasmota.set_timer(50, /->toggle_power())
    end
    
    tasmota.resp_cmnd_done()
end

# Handle a power report provided by Home Assistant:

def on_power_report(topic, idx, payload_s, payload_b)
    var payload_json = json.load(payload_s)

    print("on_power_report: ", payload_s)

    current_power = payload_json.find("CurrentPower")
    remaining_power = payload_json.find("RemainingPower")
    power_report_time = tasmota.rtc().find("local")

    return true
end

# Reacts to a neighbour heater requests:

def on_heat_request(topic, idx, payload_s, payload_b)
    var payload_json = json.load(payload_s)

    print("on_heat_request: ", payload_s)

    var heat_req_time = payload_json.find("HeatReqTime")
    var heat_req_id = payload_json.find("HeatReqId")
    var heat_req_state = payload_json.find("HeatReqState")

    var my_req_id = tasmota.wifi().find("mac")

    # Differentiate a local from a neighbour heat request:
    if heat_req_id != my_req_id
        last_heat_req_id = heat_req_time
        last_heat_req_time = heat_req_time
        last_heat_req_local_time = tasmota.rtc().find("local")
        last_heat_req_state = heat_req_state
    end

    return true
end

def on_chill_request(topic, idx, payload_s, payload_b)
    var payload_json = json.load(payload_s)

    print("on_chill_request: ", payload_s)

    var chill_req_time = payload_json.find("ChillReqTime")
    var chill_req_id = payload_json.find("ChillReqId")
    var chill_req_state = payload_json.find("ChillReqState")

    var my_req_id = tasmota.wifi().find("mac")

    # Differentiate a local from a neighbour heat request:
    if chill_req_id != my_req_id
        last_chill_req_id = chill_req_time
        last_chill_req_time = chill_req_time
        last_chill_req_local_time = tasmota.rtc().find("local")
        last_chill_req_state = chill_req_state
    end

    return true
end

def reserve_heat()
    print("reserve_heat: doing reserve_heat")
    mqtt.publish("cmnd/heaters/HeatRequest", '{ "HeatReqTime": ' +  str(tasmota.rtc().find("local")) + ', "HeatReqId": "'  + tasmota.wifi().find("mac") + '", "HeatReqState": 0 }')

    if curr_state > 0
        curr_state = 2
    end
end

def reserve_chill()
    print("reserve_chill: doing reserve_chill")
    mqtt.publish("cmnd/heaters/ChillRequest", '{ "ChillReqTime":' +  str(tasmota.rtc().find("local")) + ', "ChillReqId": "'  + tasmota.wifi().find("mac") + '", "ChillReqState": 0 }')

    if curr_state > 0
        curr_state = 4
    end
end

def commit_heat()
    print("commit_heat: doing commit_heat")

    var curr_time = tasmota.rtc().find("local")
    var last_heat_req_age = curr_time - last_heat_req_local_time
    var last_power_report_age = curr_time - power_report_time

    if curr_state == 2 && remaining_power > HEATER_POWER && last_power_report_age < REPORT_PERIOD && ( last_heat_req_state < 1 || (last_heat_req_state > 0 && last_heat_req_age > WAIT_PERIOD))
        mqtt.publish("cmnd/heaters/HeatRequest", '{ "HeatReqTime": ' +  str(curr_time) + ', "HeatReqId": "'  + tasmota.wifi().find("mac") + '", "HeatReqState": 1 }')

        # Enable the heater:
        set_heater_state(1)

        curr_state = 3
    end
end

def commit_chill()
    print("commit_chill: doing commit_chill")

    var curr_time = tasmota.rtc().find("local")
    var last_chill_req_age = curr_time - last_chill_req_local_time
    var last_power_report_age = curr_time - power_report_time

    if curr_state == 4 && remaining_power <= 0 && last_power_report_age < REPORT_PERIOD && ( last_chill_req_state < 1 || (last_chill_req_state > 0 && last_chill_req_age > WAIT_PERIOD))
        mqtt.publish("cmnd/heaters/ChillRequest", '{ "ChillReqTime":' +  str(curr_time) + ', "ChillReqId": "'  + tasmota.wifi().find("mac") + '", "ChillReqState": 1 }')

        # Disable the heater:
        set_heater_state(0)

        curr_state = 2
    end
end

# Pushes a request to enable the heater.

def request_heat()
    print("request_heat: doing request_heat")

    if curr_state == 2
        # Check if enough time went by since another device requested heat:

        var curr_time = tasmota.rtc().find("local")

        if remaining_power > HEATER_POWER && curr_time - last_heat_req_local_time > WAIT_PERIOD
            # Give it a random delay in order to give opportunity to other heaters:
            var delay = math.rand() % 10000

            tasmota.set_timer(delay, /-> reserve_heat())
            tasmota.set_timer(delay + WAIT_PERIOD * 1000, /-> commit_heat())
        end
    end
end

# Pushes a request to disable the heater.
# Only goes through if the current power consumption is above the limit.
def request_chill()
    print("request_chill: doing request_chill")

    if curr_state == 3
        var curr_time = tasmota.rtc().find("local")
        
        if remaining_power <= 0 && curr_time - last_chill_req_local_time > WAIT_PERIOD
            var delay = math.rand() % 10000

            tasmota.set_timer(delay, /-> reserve_chill())
            tasmota.set_timer(delay + WAIT_PERIOD * 1000, /-> commit_chill())
        end
    end
end

def subscribe_mqtt()
  mqtt.subscribe("tele/heaters/PowerReport", on_power_report)
  mqtt.subscribe("cmnd/heaters/HeatRequest", on_heat_request)
  mqtt.subscribe("cmnd/heaters/ChillRequest", on_chill_request)
end

def on_grace_heat_end()
    tasmota.set_timer(0, /->set_heater_state(0))
    curr_state = 2
end

def on_power_toggle(value)
    print("on_power_toggle: switch current state: ", value)

    if value == "ON"
        tasmota.set_timer(0, /->set_heater_state(1))
        tasmota.set_timer(GRACE_HEAT_PERIOD, /-> on_grace_heat_end())
        curr_state = 1 # Switch to grace heat after the heat is manually turned on
    else
        tasmota.set_timer(0, /->set_heater_state(0))  
        curr_state = 0
    end
end


# Commands:

tasmota.add_cmd('StartHeat', start_heat)
tasmota.add_cmd('StopHeat', stop_heat)

# Rules:

tasmota.add_rule("MQTT#Connected=1", subscribe_mqtt)
tasmota.add_rule("Switch1#Action", def (value) on_power_toggle(value) end )

# Cron triggers:

tasmota.add_cron("*/" + str(REPORT_PERIOD) + " * * * * *", /-> request_heat(), "request_heat")
tasmota.add_cron("*/" + str(REPORT_PERIOD) + " * * * * *", /-> request_chill(), "request_chill")
