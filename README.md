# Clustered Heating Controller

## Overview

The motivation for this project was to be able to use electric heaters to control the temperature in multiple
rooms in the same house, while at the same time ensuring the fair use of the available electric power among these.

The support for the Berry language which is included in the Tasmota 32 releases, is an exceptional capability
allowing users to code complex logic and even device drivers as instructions that are compiled in runtime by 
the interpreter.

Given the low cost of ESP32 hardware, I decided to incorporate a dev board of this type (LC Technology AC90V-250V 
1 Relay ESP32 board) into a set of Delba electric heaters:

https://templates.blakadder.com/ESP32_Relay_AC_X1.html


These are pretty conventional ceramic heater devices, which feature the PTC
heater elements, an electronic thermostat board, a fan and an IR remote control.

<img src="docs/images/delba_heater.jpg" alt="Delba Heater" width="500"/>

This script should easily be adapted to other types of devices using this type of relay board.

Besides the relay board, I have added a DS18B20 temperature sensor (for measuring the air temperature), 
a analog Current Transformer to monitor the current consumed by each heater, an IR LED for sending 
commands to the heater (emulating the IR remote control), and an optocoupler to pickup the signal of
the fan when is on (this way obtaining feedback on the user having turned on the heater).

In this adaptation process I looked forward to be the least invasive as possible to the original
hardware, in order not to have any interference with the safety aspects of the original design, and
also not to bring additional failure modes. As such I kept the ESP32 totally isolated from the heater own
electronics and the communication with its control board is only done via IR signals, and via the optocoupler.

<img src="docs/images/delba_heater_mod.jpg" alt="Delba Heater" width="500"/>

To control power, the relay on the ESP32 board is used to actuate the original relays from the heater,
by being connected in series with the coil and the transistors that drive these coils (which are 
part of the original heater control board). As such the ESP32 board is unable to independently 
turn on the heater elements, requiring the heater control board to also turn on the relays in order
to close the circuit. Even though the heater also has a thermal fuse and a thermal circuit breaker,
I preferred not to take chances and keep the original power control path untouched.

This ESP32 board also has the advantage of having its own SMPS 230 Volt isolated power supply. 

<img src="docs/images/ESP32_Relay_AC_X1.webp" alt="ESP32 Relay board" width="500"/>

This is an advantage if electrical interface with other devices would be required, as the heater control board 
IS NOT an isolated circuit. To produce the  5 VDC required for operation, it uses a uninsolated DC converter 
chip which converts the mains voltage directly to low voltage DC without galvanic isolation. This is very 
common in these types of home appliances.

## Features

This Berry script provides the following features:

 * Loop control of how many heaters remain turned on, based on metering data and power budget provided via MQTT to these;
 * Ability to cycle between heaters when running with power constraints;
 * Ability to remote control the heaters and their features exposed via IR interface (temperature setting, power, timer, etc);
 * Interprets AC current sensor feedback for adjust loop control and doze mode;
 * Heater on/off status feedback;
 * Driver for exposing control loop parameters and status;


## Operation

### Control loop

The script expects a message to be periodically (ideally below PWR_RPRT_TIMEOUT seconds) sent to the topic:

```
tele/heaters/PowerReport
```

This message must provide the realtime measurement on the active power consumption. This can usually be obtained from 
a MODBUS capable electricity meter or from an equivalent kind of energy meter installed in the house. 
It is important that the reported values reflect the consumption of the entire circuit (e.g. house) where the
loads are connected to.

The message has the following structure:

```
{ 
  "CurrentPower": integer,
  "RemainingPower": integer
}
```

Where `CurrentPower` corresponds to the active power currently being consumed, and `RemainingPower` is 
the amount of power margin still available before the circuit breaker cuts the power (you may for example define it 
as the difference between the contracted power and the active power).

Based on this information, we have the "error signal" that causes the control loop to take action and 
force one or more of the nodes (heaters) to change state.

The state machine is described by the diagram below:

<img src="docs/images/clustered-heating-controler-fsm.png" alt="Clustered Heating Controler FSM" width="500"/>

Besides being idle or heating, when the heater is first turned on, it first goes through the "Grace Heat"
intermediate state, where it is given the chance to turn on the heating element for a while, even if the 
power budget is overrun during that period. This period can be adjusted through the GRACE_HEAT_PERIOD variable.
Nevertheless if there are more heaters from the cluster running, one of these will turn itself off to keep
the power demand below the limit. The reason for this "Grace Heat" state is so that the user can get the 
perception the heater is running normally and producing heat once it is turned on.

### Commands

This script exposes two Tasmota commands:

**StartHeat** - this command instructs the heater to start running. The parameters and modes defined 
via this command map to the Delba heater built in features that are normally called via IR commands.

It takes the following payload:

```
{ 
  "HeatMode": integer,
  "TargetTemperature": integer,
  "Duration": integer,
  "HeatLevel": integer
}
```

`HeatMode` is the only mandatory parameter, and it specifies if the heater will be running in thermostat mode
or power mode. All other parameters are optional and context dependent. 

As such, if we want to run the heater in **temperature mode**  we need to pass the following payload:

```
{
  "HeatMode": 0,
  "TargetTemperature": 23
}
```

Where `TargetTemperature` is the target temperature in degrees Celsius.

We can also optionally limit the heating duration to 2 hours by passing the argument:

```
{
  "HeatMode": 0,
  "TargetTemperature": 23,
  "Duration": 2
}
```

but if we want to run the heater in **power mode**, we need to provide the following arguments:

```
{
  "HeatMode": 1,
  "HeatLevel": 1
}
```

Where `HeatLevel` has the following 3 possible values:

 * 0 - no heating, only the fan recirculating air;
 * 1 - half power setting (approx. 1000 Watts)
 * 2 - full power setting (approx. 2000 Watts)

<br>

**StopHeat** - commands the heater to stop. This command takes no arguments.

## Data Model

### Power Usage messages

The heater cluster relies on the exchange of some messages types via MQTT in order to achieve the coordinated operation
it is designed for.

#### Power consumption report

First there is the above mentioned power report message which is provided by an external system (e.g. Home Assistant).

```
{
  "CurrentPower": integer,
  "RemainingPower": integer
}
```

#### HeatRequest message

During the operation of each heater, whenever a heater intends to turn its heating element on, it
sends a HeatRequest message to the cmnd/heaters/HeatRequest topic:

```
{
  "HeatReqTime": integer,
  "HeatReqId": "FF:FF:FF:FF:FF:FF",
  "HeatReqState": 0
}
```

This is a preparation message ("HeatReqState": 0 means reservation), and other heaters which haven't yet sent a similar 
request, will give up and try later.

A while after this message is sent, there is another similar message which is called a commit message:

```
{
  "HeatReqTime": integer,
  "HeatReqId": "FF:FF:FF:FF:FF:FF",
  "HeatReqState": 1
}
```

When the device sends this message it means there is no turning back, and it just announcing that will turn its heater
on. Before this message is sent, the device first checks if there was no other device doing the same in 
the short term. If yes, it gives up and waits for the next opportunity.

#### ChillRequest message

Similarly to the HeatRequest messages, there is also a ChillRequest that is sent to the cmnd/heaters/ChillRequest

```
{
  "ChillReqTime": integer,
  "ChillReqId": "FF:FF:FF:FF:FF:FF",
  "ChillReqState": 0
}
```

This is the opposite of the HeatRequest message, as it requests the intention to turn off the heater element. The reason
for this type of request is because as the power budget becomes insufficient for all heaters, we want to disable 
the minimum number of heaters while still staying below the limits. With this approach we avoid that all devices 
react to the insufficient power condition at the same time and turn their heat off simultaneously.

Here there is also a commit message, once the device is set to turn its heater off:

```
{
  "ChillReqTime": integer,
  "ChillReqId": "FF:FF:FF:FF:FF:FF",
  "ChillReqState": 1
}
```

#### StateReport message

When multiple heaters are running at the margin of the available power, without any additional measure, 
these would reach a steady state where the same set of heaters would stay on, while one ore more
of the heaters would stay off until the power budget would change. This means that these heaters
would get into starvation and not being given the opportunity to heat the room.

In order to prevent this, each device provides a special status message that is published to cmnd/heaters/StateReport.

This message looks like the following:

```
{
  "Time": integer,
  "Mac": "FF:FF:FF:FF:FF:FF",
  "State": integer
}
```

As every device reads this message, each one is able to build and keep up to date a table containing 
the status of each device. With this information a order number is computed based on the MAC address of each device. 
This order number allows each device to be assigned a unique timeslot for a given time frame (e.g. 60 minutes).

With this timeslot, each device knows that when its time arrived and consumption is at the margin, it
must turn itself off to give opportunity to another device. This way we even out the overall time that 
each heater is running, ensuring even heating across all rooms.

## Installation

1. Create or edit the autoexec.be file with the following line:

```
load('heater_control.be')
```

2. Upload the heater_control.be script to the Tasmota device.

## Configuration

### Tasmota

In Tasmota you need to make sure that the IO ports are correctly configured for the peripherals
used by this script. I have chosen the following layout:

```
Module type (ESP32-DevKit)

ESP32_Relay_AC_X1 (0)

IO GPIO27;DS18x20;1
AO GPIO32;Switch;1
AO GPIO33;IRsend;1
IA GPIO34;ADC CT Power;1
```

Next you need to make sure that each heater is set for the heaters shared topic.

```
GroupTopic2 heaters
```

### Energy consumption message

For example if you have Home Assistant with an integration to a metering device already in place, you can easily configure
an automation to report the power to the heaters:

```
- id: power_report
  alias: power_report
  trigger:
    platform: time_pattern
    seconds: "/5"
  action:
    - service: mqtt.publish
      data:
        topic: "tele/heaters/PowerReport"
        payload: '{{ { "CurrentPower": states("sensor.mains_active_power") | int, "RemainingPower": 6900 - (states("sensor.mains_active_power") | int) } | tojson }}'
```

The  above automation will publish the power consumption message to the heaters every 5 seconds. The 6900 Watts represents 
the maximum power of the circuit breaker, and can be replaced with the most appropriate for the user scenario.

## TODO

  * Optimize behaviour on Wifi / MQTT connectivity issues;
  * Use the DS18B20 as an independent temperature sensor for implementing custom thermostat and/or failsafe;
  * Use the CT current sensor for detecting failure conditions (e.g. relay latching / heater never turning off);
