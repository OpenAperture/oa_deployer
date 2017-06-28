#!/bin/bash

set -e

mix deps.get
mix escript.build
