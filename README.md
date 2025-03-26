# Compiling & Testing

```
brew install ffmpeg cmake git
git submodule update --init --recursive
$PWD/build.sh Debug
$PWD/run.sh 2>&1 | tee $PWD/run.log
```

# Output Expectation

The following output corresponds with the VideoToolbox Encoder's "`47564adc-5c4c-433f-94ef-c5113cd143a8`" UUID:

```
0.8: forbidden_zero_bit: 0 
0.7: nal->nal_ref_idc: 0 
0.5: nal->nal_unit_type: 6 
3.8: sei_uud->uuid[i]: 71 
4.8: sei_uud->uuid[i]: 86 
5.8: sei_uud->uuid[i]: 74 
6.8: sei_uud->uuid[i]: 220 
7.8: sei_uud->uuid[i]: 92 
8.8: sei_uud->uuid[i]: 76 
9.8: sei_uud->uuid[i]: 67 
10.8: sei_uud->uuid[i]: 63 
11.8: sei_uud->uuid[i]: 148 
12.8: sei_uud->uuid[i]: 239 
13.8: sei_uud->uuid[i]: 197 
14.8: sei_uud->uuid[i]: 17 
15.8: sei_uud->uuid[i]: 60 
16.8: sei_uud->uuid[i]: 209 
17.8: sei_uud->uuid[i]: 67 
18.8: sei_uud->uuid[i]: 168 
19.8: sei_uud->user_data[i]: 1 
20.8: sei_uud->user_data[i]: 255 
21.8: sei_uud->user_data[i]: 204 
22.8: sei_uud->user_data[i]: 204 
23.8: sei_uud->user_data[i]: 255 
24.8: sei_uud->user_data[i]: 2 
25.8: sei_uud->user_data[i]: 0 
26.8: sei_uud->user_data[i]: 8 
27.8: sei_uud->user_data[i]: 100 
28.8: sei_uud->user_data[i]: 112
```
