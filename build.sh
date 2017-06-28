#!/bin/bash

set -e

mix deps.get
escript.build
