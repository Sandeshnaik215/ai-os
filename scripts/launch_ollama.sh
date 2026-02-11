#!/bin/bash
exec nice -n 0 ionice -c 2 -n 0 /usr/bin/ollama serve
