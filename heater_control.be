import mqtt
import json
import math
import string

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

curr_heater_power = 0
curr_temperature = -1
curr_heat_level = -1
curr_duration = -1
curr_heat_mode = 0 # 0 = Temperature; 1 = Power
curr_power_state = "off" #  off | fan_only | heat_low | heat_high


heaters = map()

DEFAULT_TEMP=18
PWR_RPRT_TIMEOUT = 10
REQUEST_PERIOD = 4
SENSOR_PERIOD = 2
GRACE_HEAT_PERIOD = 10000
STATE_PUB_PERIOD = 5
DOZE_DEAD_BAND = 1000
DOZE_CYCLE = 60000

HEATER_MAX_POWER = 1000
MIN_RELEVANT_POWER = 100
DEFAULT_HEAT_LEVEL=1  # 0 = no heat; 1 = minimum; 2 = maximum
HEAT_LOW_POWER = 1200
HEAT_HIGH_POWER = 2400

STATE_MAX_AGE = 15

DEBUG=true

notif_topic = "tele/" + tasmota.cmd("hostname", false).find("Hostname") + "/EVENT"

class state_report
    var time, mac, state, order_num

    def init(time, mac, state, order_num)
        self.time = time
        self.mac = mac
        self.state = state
        self.order_num = order_num
    end
end

### Utility functions:

def order_from_mac(mac)
    var mac_suffix = string.replace(string.split(mac, 6)[1],":","")

    return bytes(mac_suffix).get(0,-4)
end

def bubble_sort(entries)
    for i: 0..size(entries) - 1
        var swapped = false
        
        for j: 0..(size(entries) - i - 2)
            if order_from_mac(entries[j].mac) > order_from_mac(entries[j+1].mac)
                var temp = entries[j]
                entries[j] = entries[j+1]
                entries[j+1] = temp
        
                swapped = true
            end
        end

        if ! swapped
            break
        end
    end
end

def recalculate_order()
    var entries = []

    # Populate the list:
    for k: heaters.keys()
        entries.push(heaters.item(k))
    end

    bubble_sort(entries)

    # Update the heaters status map with the order number of each entry
    for i: 0..(size(entries) - 1)
        entries[i].order_num = i
        heaters.setitem(entries[i].mac, entries[i])
    end
end

def print_state_table()
    for k: heaters.keys()
        var heater = heaters.item(k)
        print("print_state_table: time: ", str(heater.time), "; mac: ", heater.mac, "; state: ", str(heater.state), "; order_num: ", str(heater.order_num))
    end
end

### IR remote commands:

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

def set_temperature(temp)
    temperature_mode()
    reset_temperature()

    for i:0..temp-19
        tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FEA05F"}')
    end
end

def toggle_power()
    tasmota.cmd('IRSend {"Protocol":"NEC","Bits":32,"Data":"0x01FE48B7"}')
end

### Heater management relay:

def set_heater_state(state)
    tasmota.cmd('Power1 ' + str(state))
end

def set_curr_state(state)
    curr_state = state
end

def start_heat(cmd, idx, payload, payload_json)
    var temperature = nil
    var duration = nil
    var heat_mode = 1
    var heat_level = nil

    # parse payload
    if payload_json != nil 
        if  payload_json.find("TargetTemperature") != nil 
            temperature = int(payload_json.find("TargetTemperature"))
        end

        if payload_json.find("Duration") != nil
            duration = int(payload_json.find("Duration"))
        end

        if payload_json.find("HeatMode") != nil
            heat_mode = int(payload_json.find("HeatMode"))
        end

        if payload_json.find("HeatLevel") != nil
            heat_level = int(payload_json.find("HeatLevel"))
        end
    end

    if ! tasmota.get_switches()[0]
        tasmota.set_timer(0, /->toggle_power())
    else
        # Cycle the power to make sure in the next step we set to the intended heat level:
        tasmota.set_timer(0, /->toggle_power())
        tasmota.set_timer(50, /->toggle_power())
    end

    # Set to the desired operation mode:

    if  heat_mode == 0 
        if temperature == nil
            temperature = DEFAULT_TEMP
        end

        tasmota.set_timer(500, /->set_temperature(temperature))

        curr_temperature = temperature 
    elif heat_mode == 1
        if heat_level == nil
            heat_level = DEFAULT_HEAT_LEVEL
        end

        for i:1..heat_level
            tasmota.set_timer(i * 100, /->toggle_heat_mode())
        end

        curr_heat_level = heat_level
    end

    curr_heat_mode = heat_mode
    tasmota.set_timer(100, /->set_heater_state(1))

    if duration != nil
        tasmota.set_timer(15000, /->set_timer(duration))
        curr_duration = duration
    end    
    
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

    if curr_state > 0 && curr_state != 3
        curr_state = 2
    end
end

def reserve_chill()
    print("reserve_chill: doing reserve_chill")
    mqtt.publish("cmnd/heaters/ChillRequest", '{ "ChillReqTime":' +  str(tasmota.rtc().find("local")) + ', "ChillReqId": "'  + tasmota.wifi().find("mac") + '", "ChillReqState": 0 }')

    if curr_state > 0 && curr_state != 2
        curr_state = 4
    end
end

def commit_heat()
    print("commit_heat: doing commit_heat")

    var curr_time = tasmota.rtc().find("local")
    var last_heat_req_age = curr_time - last_heat_req_local_time
    var last_power_report_age = curr_time - power_report_time

    if curr_state == 2 && remaining_power > curr_heater_power && last_power_report_age < PWR_RPRT_TIMEOUT && ( last_heat_req_state < 1 || (last_heat_req_state > 0 && last_heat_req_age > REQUEST_PERIOD))
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

    if curr_state == 4 && remaining_power <= 0 && last_power_report_age < PWR_RPRT_TIMEOUT && ( last_chill_req_state < 1 || (last_chill_req_state > 0 && last_chill_req_age > REQUEST_PERIOD))
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

        if remaining_power > curr_heater_power && curr_time - last_heat_req_local_time > REQUEST_PERIOD
            # Give it a random delay in order to give opportunity to other heaters:
            var delay = math.rand() % (REQUEST_PERIOD * 300)

            tasmota.set_timer(delay, /-> reserve_heat())
            tasmota.set_timer(delay + REQUEST_PERIOD * 300, /-> commit_heat())
        end
    end
end

# Pushes a request to disable the heater.
# Only goes through if the current power consumption is above the limit.
def request_chill()
    print("request_chill: doing request_chill")

    if curr_state == 3
        var curr_time = tasmota.rtc().find("local")
        
        if remaining_power <= 0 && curr_time - last_chill_req_local_time > REQUEST_PERIOD
            var delay = math.rand() % (REQUEST_PERIOD * 300)

            tasmota.set_timer(delay, /-> reserve_chill())
            tasmota.set_timer(delay + REQUEST_PERIOD * 300, /-> commit_chill())
        end

        return
    end

    # Capture timed-out chill requests:

    if curr_state == 4
        curr_state = 3
    end
end

def publish_state()
    mqtt.publish('cmnd/heaters/StateReport', '{ "Time": ' +  str(tasmota.rtc().find("local")) + ', "Mac": "'  + tasmota.wifi().find("mac") + '", "State": ' + str(curr_state) + '}')
end

def read_power_state()
    var sensors = json.load(tasmota.read_sensors())
    var power = sensors['ANALOG']['CTEnergy1']['Power']
    var fan = sensors['Switch1']

    if power != nil && fan != nil
        if power > MIN_RELEVANT_POWER
            curr_heater_power = power
        end

        if fan == "OFF" && power < MIN_RELEVANT_POWER
            curr_power_state = "off"
        elif fan == "ON" && power < MIN_RELEVANT_POWER
            curr_power_state = "fan_only"
        elif fan == "ON" && power > MIN_RELEVANT_POWER && power < HEAT_LOW_POWER
            curr_power_state = "heat_low"
        elif fan == "ON" && power > HEAT_LOW_POWER && power < HEAT_HIGH_POWER
            curr_power_state = "heat_high"
        else
            # Error:
            print("read_power_state: unexpected power state. Please check heater!")
            mqtt.publish(notif_topic, "{\"event_type\":\"error\", \"detail\":\"heater_abnormal_state\"}")
        end
    end
end

def on_doze_cron()
    print("on_doze_cron: doze mode triggered for this heater.")

    if curr_state > 1
        tasmota.set_timer(0, /->set_heater_state(0))
        set_curr_state(0)
        tasmota.set_timer((DOZE_CYCLE / size(heaters)) - DOZE_DEAD_BAND, def () set_curr_state(2) end)
    end
end

def set_doze_cron()
    var this_mac = tasmota.wifi().find("mac")

    if heaters.contains(this_mac)
        var this_heater = heaters.item(this_mac)

        tasmota.remove_cron("doze_cron")

        # if power margin is low we assume that cycling between heaters is required:
        # TODO consider the state table size and the wifi connection state as well.
        if size(heaters) > 1 && remaining_power < HEATER_MAX_POWER
            tasmota.add_cron(str((60 * this_heater.order_num) / size(heaters)) + " * * * * *", /-> on_doze_cron(), "doze_cron")
        end
    end
end

def on_state_report(topic, idx, payload_s, payload_b)
    var payload_json = json.load(payload_s)

    print("on_state_report: ", payload_s)

    var time = payload_json.find("Time")
    var mac = payload_json.find("Mac")
    var state = payload_json.find("State")

    var state_report = state_report(time, mac, state, -1)

    if ! heaters.contains(mac)
        heaters.insert(mac, state_report)
    else
        heaters.setitem(mac, state_report)
    end

    # Search if there are entries older than a certain age
    # and remove these.

    var curr_time = tasmota.rtc().find("local")

    for k: heaters.keys()
        var heater = heaters.item(k)
        if curr_time - heater.time > STATE_MAX_AGE
            heaters.remove(k)
        end
    end
    
    # Recalculate the order number of each device in the map:

    recalculate_order()

    if DEBUG
        tasmota.set_timer(0, /->print_state_table())
    end

    # Redefine the cron for when this heater enters doze mode:

    if curr_state > 1
        tasmota.set_timer(0, /->set_doze_cron())
    end

    return true
end

def on_grace_heat_end()
    set_heater_state(0)
    curr_state = 2
end

def activate_heater()
    tasmota.set_timer(GRACE_HEAT_PERIOD, /-> on_grace_heat_end())
    tasmota.add_cron("*/" + str(STATE_PUB_PERIOD) + " * * * * *", /-> publish_state(), "publish_state")
    tasmota.add_cron("*/" + str(REQUEST_PERIOD) + " * * * * *", /-> request_heat(), "request_heat")
    tasmota.add_cron("*/" + str(REQUEST_PERIOD) + " * * * * *", /-> request_chill(), "request_chill")

    mqtt.subscribe("tele/heaters/PowerReport", on_power_report)
    mqtt.subscribe("cmnd/heaters/HeatRequest", on_heat_request)
    mqtt.subscribe("cmnd/heaters/ChillRequest", on_chill_request)
    mqtt.subscribe("cmnd/heaters/StateReport", on_state_report)

    set_heater_state(1)
    curr_state = 1 # Switch to grace heat after the heat is manually turned on
end

def deactivate_heater()
    set_heater_state(0)
    curr_state = 0

    mqtt.unsubscribe("tele/heaters/PowerReport")
    mqtt.unsubscribe("cmnd/heaters/HeatRequest")
    mqtt.unsubscribe("cmnd/heaters/ChillRequest")
    mqtt.unsubscribe("cmnd/heaters/StateReport")

    tasmota.remove_cron("request_heat")
    tasmota.remove_cron("request_chill")
    tasmota.remove_cron("doze_cron")
    tasmota.remove_cron("publish_state")

    curr_heater_power = 0
end

def on_power_toggle(value)
    print("on_power_toggle: switch current state: ", value)

    if value == "ON"
        tasmota.set_timer(0, /-> activate_heater())
    else
        tasmota.set_timer(0, /-> deactivate_heater())
    end
end


# Commands:

tasmota.add_cmd('StartHeat', start_heat)
tasmota.add_cmd('StopHeat', /-> stop_heat())

# Rules:

tasmota.add_rule("Switch1#Action", def (value) on_power_toggle(value) end )

# Cron (persistent):

tasmota.add_cron("*/" + str(SENSOR_PERIOD) + " * * * * *", /-> read_power_state(), "read_power_state")


# Heater Driver

class HeatingController
    def json_append()
        var msg = string.format(",\"HeatingController\":{\"TargetTemperature\":%i,\"Duration\":%i,\"HeatMode\":%i,\"HeatLevel\":%i,\"PowerState\":\"%s\"}", curr_temperature, curr_duration, curr_heat_mode, curr_heat_level, curr_power_state)

        tasmota.response_append(msg)
    end
end

heating_controller = HeatingController()

tasmota.add_driver(heating_controller)
