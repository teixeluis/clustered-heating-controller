#! /bin/sh

curl -d @heater_control.be -X POST http://192.168.1.139/ufsu
curl -d @heater_control.be -X POST http://192.168.1.157/ufsu

