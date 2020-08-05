#!/bin/bash

echo "Fetching Ananke theme..."
wget https://github.com/theNewDynamic/gohugo-theme-ananke/archive/v2.6.2.tar.gz

echo "Extract and install theme..."
tar -xzf v2.6.2.tar.gz -C themes

echo "Cleaning up..."
rm v2.6.2.tar.gz

echo "Done"
