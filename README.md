# Delba Heater

## Overview

This motivation for this project was to be able to use electric heaters to control the temperature in multiple
rooms in the same house, while at the same time ensuring the fair use of the available electric power among these.

The support for the Berry language which is included in the Tasmota 32 releases, is an exceptional capability
allowing users to code complex logic and even device drivers as instructions that are compiled in runtime by 
the interpreter.

Given the low cost of ESP32 hardware, I decided to incorporate a dev board of this type (LC Technology AC90V-250V 1 Relay ESP32 board):

https://templates.blakadder.com/ESP32_Relay_AC_X1.html

into a set of Delba electric heaters. These are pretty conventional ceramic heater devices, which feature the PTC
heater elements, an electronic thermostat board, a fan and an IR remote control.

This script should easily be adapted to other types of devices using this type of relay board.

Besides the relay board, I have added a DS18B20 temperature sensor (for measuring the air temperature), a cheap 
analog Current Transformer to monitor the current consumed by each heater, an IR LED for sending 
commands to the heater (emulating the IR remote control), and an optocoupler to pickup the signal of
the fan being on (this way obtaining feedback on the user having turned on the heater).

In this adaptation process I looked forward to be the least invasive as possible to the original
hardware, in order not to have any interference with the safety aspects of the original design, and
also not bring potential failure modes. As such I kept the ESP32 totally isolated from the heater own
electronics. The communication with its control board is only done via IR signals, and via the optocoupler.
To control power, the relay on the ESP32 board is used to actuate the original relays from the heater,
by being connected in series with the coil and the transistors that drive these coils (which are 
part of the original heater control board). As such the ESP32 board is unable to independently 
turn on the heater elements, requiring the heater control board to also turn on the relays in order
to close the circuit. Even though the heater also has a thermal fuse and a thermal circuit breaker,
I preferred not to take chances and keep things isolated.

This ESP32 board also has the advantage of having its own SMPS 230 Volt isolated power supply. 
This is an advantage if electrical interface with other devices would be required for example,
as the heater control board IS NOT an isolated circuit. To produce the  5 VDC required for 
operation, it uses a uninsolated DC converter chip which converts the mains voltage directly to
low voltage DC without galvanic isolation. This is very common in these types of home appliances.


## Installation

1. Create or edit the autoexec.be file with the following line:

```
load('heater_control.be')
```

## Features



## Data Model

### Power Usage messages

The heaters are able to ration power usage based on the power usage messages provided by Home Assistant.
These messages have the following format:

```
{ "CurrentPower": integer, "RemainingPower": integer }

```

This provides the current power being consumed by the house in watts, and the power budget
still available for the heaters.




## TODO

  * Optimize behaviour on Wifi / MQTT connectivity issues;

