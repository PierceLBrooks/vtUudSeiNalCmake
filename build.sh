#!/bin/sh

rm $PWD/build.log
rm -rf $PWD/build
rm -rf $PWD/install
mkdir -p $PWD/build
cd $PWD/build
cmake -G Xcode -S .. -DCMAKE_INSTALL_PREFIX=../install -DCMAKE_BUILD_TYPE=$@
cd ..
cmake --build build --target install --config $@ 2>&1 | tee build.log

