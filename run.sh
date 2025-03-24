#!/bin/sh

rm $PWD/h264_analyze
rm $PWD/svc_split
rm $PWD/VtUudSeiNalCmake
cp $PWD/install/bin/h264_analyze $PWD/h264_analyze
cp $PWD/install/bin/svc_split $PWD/svc_split
cp $PWD/install/bin/VtUudSeiNalCmake $PWD/VtUudSeiNalCmake
ruby $PWD/codesign.rb $PWD/h264_analyze
ruby $PWD/codesign.rb $PWD/svc_split
ruby $PWD/codesign.rb $PWD/VtUudSeiNalCmake
#$PWD/svg_split $PWD/test.264
ffmpeg -i "$PWD/test.264" "$PWD/test.mp4"
ffmpeg -i "$PWD/test.mp4" -f image2 -vcodec copy -bsf h264_mp4toannexb "$PWD/test.264_%d"
#lldb -o run $PWD/h264_analyze -- $PWD/test.264
lldb -o run $PWD/VtUudSeiNalCmake -- $PWD/test.264

