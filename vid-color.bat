:: parameter 1 = config file
:: parameter 2 = input video
:: parameter 3 = output video

::+++++++++++++++++++++++++::
:: Check cmdline arguments ::
::+++++++++++++++++++++++++::

@echo off & setlocal EnableDelayedExpansion
::setlocal EnableDelayedExpansion

if [%1] neq [] if [%2] neq [] goto :ARGS_OK
	echo. & echo USAGE:    %~n0 configFile inputVideo [outputVideo]
	echo. & echo   If outputVideo is omitted, the input filename will be appended with
	echo   "_OUT" for the output file. & exit /b
:ARGS_OK
	if [%3] neq [] (
		set OUTFILE=%~f3
		set OUTEXT=%~x3
	) else (
		set OUTFILE=%~d2%~p2%~n2_OUT%~x2
		set OUTEXT=%~x2
	)
	if exist %1 goto :FILE1_OK
	echo. & echo File not found: %1 & exit /b
:FILE1_OK
	if exist %2 goto :FILE2_OK
	echo. & echo File not found: %2 & exit /b
:FILE2_OK
	if [%OUTEXT%] neq [] goto :FILES_OK
	echo. & echo Output filename must have an extension: %OUTFILE% & exit /b
:FILES_OK


::+++++++++++++++++++++++::
:: Find input dimensions ::
::+++++++++++++++++++++++::

set IX= & SET IY= & for /f %%i IN ('ffprobe -hide_banner -show_entries stream^=width^,height %2 ^| find "="') do (
	set x=%%i
	if "!x:~0,6!"=="width=" SET IX=!x:~6!
	if "!x:~0,7!"=="height=" SET IY=!x:~7!
)
if "%IX%" neq " " if "%IY%" neq " " goto :ALL_OK
echo. & echo Couldn't get valid width/height for input video "%2"^^^! & exit /b
:ALL_OK


::++++++++++::
:: Settings ::
::++++++++++::

FOR /F "eol=; tokens=1,2" %%i in (%1) do SET %%i=%%j
if not exist _%OVL_TYPE%.png (echo File not found: _%OVL_TYPE%.png & exit /b)

set /a "PX=IX*SX"
set /a "PY=IY*SY"
set OX=round(%OY%*4/3)
set SWSFLAGS=accurate_rnd+full_chroma_int+full_chroma_inp
if /i "%VIGNETTE_ON%"=="yes" (SET VIGNETTE_STR=vignette=PI*%VIGNETTE_POWER%, ) else (SET VIGNETTE_STR=)
if /i "%V_PX_BLUR%"=="0" (SET VSIGMA=0.1) else (SET VSIGMA=%V_PX_BLUR%/100*%SY%)
if "%CURVATURE%" neq "0" (
	SET LENSC=, lenscorrection=k1=%CURVATURE%:k2=%CURVATURE%
	SET LENSC_NO_MOIRE=, scale=iw*4:ih*4:flags=neighbor!LENSC!, scale=iw/4:ih/4:flags=lanczos
)
if /i "%SCAN_FACTOR%"=="half" (
	SET SCAN_FACTOR=0.5
	SET /a SL_COUNT=IY/2
) else (
	if /i "%SCAN_FACTOR%"=="double" (
		SET SCAN_FACTOR=2
		SET /a SL_COUNT=IY*2
	) else (
		SET SCAN_FACTOR=1
		SET /a SL_COUNT=IY
	)
)

@SET FFSTART=%time%


::+++++++++++++++++++++++++++++++++++++++::
:: Create rounded corners, add curvature ::
::+++++++++++++++++++++++++++++++++++++++::

if "%CORNER_RADIUS%"=="0" (
	ffmpeg -hide_banner -y -f lavfi -i "color=c=#00000000:s=%PX%x%PY%, format=rgba" -frames:v 1 TMPcorners.png
) else ( ffmpeg -hide_banner -y -f lavfi ^
	-i "color=s=1024x1024, format=rgba, geq='a=if(lte((X-W)^2+(Y-H)^2, 1024*1024), 0, 255)':r=0:g=0:b=0, scale=%CORNER_RADIUS%:%CORNER_RADIUS%:flags=lanczos"^
	-filter_complex ^"^
		color=c=#00000000:s=%PX%x%PY%, format=rgba[bg];^
		[0] split=4 [tl][c2][c3][c4];^
		[c2] transpose=1 [tr];^
		[c3] transpose=3 [br];^
		[c4] transpose=2 [bl];^
		[bg][tl] overlay=0:0:format=rgb [p1];^
		[p1][tr] overlay=%PX%-%CORNER_RADIUS%:0:format=rgb [p2];^
		[p2][br] overlay=%PX%-%CORNER_RADIUS%:%PY%-%CORNER_RADIUS%:format=rgb [p3];^
		[p3][bl] overlay=x=0:y=%PY%-%CORNER_RADIUS%:format=rgb %LENSC%^" ^
	-frames:v 1 TMPcorners.png
)
if errorlevel 1 exit /b


::+++++++++++++++++++++++++++++++++::
:: Create scanlines, add curvature ::
::+++++++++++++++++++++++++++++++++::

if /i "%SCANLINES_ON%"=="yes" (
	ffmpeg -hide_banner -y -f lavfi ^
	-i nullsrc=s=1x100^
	-vf ^"^
		format=gray,^
		geq=lum='if^(lt^(Y,%SY%/%SCAN_FACTOR%^), pow^(sin^(Y*PI/^(%SY%/%SCAN_FACTOR%^)^), 1/%SL_WEIGHT%^)*255, 0^)',^
		crop=1:%SY%/%SCAN_FACTOR%:0:0,^
		scale=%PX%:ih:flags=neighbor^"^
	-frames:v 1 TMPscanline.png

	ffmpeg -hide_banner -y -loop 1 -framerate 1 -t %SL_COUNT% ^
	-i TMPscanline.png^
	-vf ^"^
		format=rgb24,^
		tile=layout=1x%SL_COUNT% %LENSC_NO_MOIRE%^"^
	-frames:v 1 TMPscanlines.png
	if errorlevel 1 exit /b
)


::********************************::
:: Tile shadowmask, add curvature ::
::********************************::

ffmpeg -hide_banner -y -loop 1 -framerate 1 -t 80^
	-i _%OVL_TYPE%.png^
	-filter_complex ^"^
		lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)',^
		scale=round(iw*%OVL_SCALE%):round(ih*%OVL_SCALE%):flags=lanczos+%SWSFLAGS%,^
		lutrgb='r=gammaval(0.454545):g=gammaval(0.454545):b=gammaval(0.454545)',^
		tile=layout=100x1,^
		crop=%PX%:in_h:0:0^"^
	-frames:v 1 TMPshadowmaskR.png

ffmpeg -hide_banner -y -loop 1 -framerate 1 -t 160^
	-i TMPshadowmaskR.png^
	-vf ^"^
		tile=layout=1x160,^
		crop=in_w:%PY% %LENSC_NO_MOIRE%^"^
	-frames:v 1 TMPshadowmask.png
if errorlevel 1 exit /b


::++++++++++++++++::
:: Phosphor decay ::
::++++++++++++++++::

if "%P_DECAY_FACTOR%"=="0" (set SCALESRC=%2) else (
	ffmpeg -hide_banner -y^
	-i %2 ^
	-filter_complex ^"^
		[0] split [orig][2lag]; ^
		[2lag] lagfun=%P_DECAY_FACTOR% [lag]; ^
		[orig][lag] blend=all_mode='lighten':all_opacity=%P_DECAY_ALPHA%^" ^
	-c:v libx264rgb -crf 0 TMPstep00.avi
	if errorlevel 1 exit /b
	SET SCALESRC=TMPstep00.avi
)


::++++++++++++++++++++++++++++++++++++++++++++++++++::
:: Scale nearest neighbor, apply gamma & pixel blur ::
::++++++++++++++++++++++++++++++++++++++++++++++++++::

ffmpeg -hide_banner -y^
	-i %SCALESRC% ^
	-vf ^"^
		scale=%PX%:%PY%:flags=neighbor+%SWSFLAGS%,^
		lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)',^
		gblur=sigma=%H_PX_BLUR%/100*%SX%:sigmaV=%VSIGMA%:steps=3^"^
	-c:a copy -c:v libx264rgb -crf 0 TMPstep01.avi

if errorlevel 1 exit /b


::++++++++++++++++++++++++++++++++++++++++++++::
:: Add halation, revert gamma + add curvature ::
::++++++++++++++++++++++++++++++++++++++++++++::

if /i "%HALATION_ON%"=="yes" (
	ffmpeg -hide_banner -y^
	-i TMPstep01.avi^
	-filter_complex ^"^
		[0]split[a][b],^
		[a]gblur=sigma=%HALATION_RADIUS%:steps=3[h],^
		[b][h]blend=all_mode='lighten':all_opacity=%HALATION_ALPHA%,^
		lutrgb='r=gammaval^(0.454545^):g=gammaval^(0.454545^):b=gammaval^(0.454545^)'^
		%LENSC%^"^
	-c:a copy -c:v libx264rgb -crf 0 TMPstep02.avi
) else (
	ffmpeg -hide_banner -y^
	-i TMPstep01.avi^
	-vf ^"^
		lutrgb='r=gammaval^(0.454545^):g=gammaval^(0.454545^):b=gammaval^(0.454545^)'^
		%LENSC%^"^
	-c:a copy -c:v libx264rgb -crf 0 TMPstep02.avi
)
if errorlevel 1 exit /b


::++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++::
:: Add bloom, scanlines, shadowmask, rounded corners + brightness fix ::
::++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++::

if /i "%SCANLINES_ON%"=="yes" (

	if /i "%BLOOM_ON%"=="yes" (

		ffmpeg -hide_banner -y^
		-i TMPscanlines.png -i TMPstep02.avi^
		-filter_complex ^"^
			[1]lutrgb='r=gammaval^(2.2^):g=gammaval^(2.2^):b=gammaval^(2.2^)', hue=s=0, lutrgb='r=gammaval^(0.454545^):g=gammaval^(0.454545^):b=gammaval^(0.454545^)'[g],^
			[g][0]blend=all_expr='if^(gte^(A,128^), ^(B+^(255-B^)*%BLOOM_POWER%*^(A-128^)/128^), B^)',^
			setsar=sar=1/1^"^
		-an -c:v libx264rgb -crf 0 TMPbloom.avi

		ffmpeg -hide_banner -y^
		-i TMPstep02.avi -i TMPbloom.avi -i TMPshadowmask.png -i TMPcorners.png^
		-filter_complex ^"^
			[0][1]blend=all_mode='multiply':all_opacity=%SL_ALPHA%[a],^
			[a][2]blend=all_mode='multiply':all_opacity=%OVL_ALPHA%[b],^
			[b][3]overlay=0:0:format=rgb,^
			lutrgb='r=clip^(val*%OVL_BRIGHTFIX%,0,255^):g=clip^(val*%OVL_BRIGHTFIX%,0,255^):b=clip^(val*%OVL_BRIGHTFIX%,0,255^)'^"^
		-c:a copy -c:v libx264rgb -crf 0 TMPstep03.avi

	) else (

		ffmpeg -hide_banner -y^
		-i TMPstep02.avi -i TMPscanlines.png -i TMPshadowmask.png -i TMPcorners.png^
		-filter_complex ^"^
			[0][1]blend=all_mode='multiply':all_opacity=%SL_ALPHA%[a],^
			[a][2]blend=all_mode='multiply':all_opacity=%OVL_ALPHA%[b],^
			[b][3]overlay=0:0:format=rgb,^
			lutrgb='r=clip^(val*%OVL_BRIGHTFIX%,0,255^):g=clip^(val*%OVL_BRIGHTFIX%,0,255^):b=clip^(val*%OVL_BRIGHTFIX%,0,255^)'^"^
		-c:a copy -c:v libx264rgb -crf 0 TMPstep03.avi
	)

) else (

	ffmpeg -hide_banner -y^
	-i TMPstep02.avi -i TMPshadowmask.png -i TMPcorners.png^
	-filter_complex ^"^
		[0][1]blend=all_mode='multiply':all_opacity=%OVL_ALPHA%[b],^
		[b][2]overlay=0:0:format=rgb,^
		lutrgb='r=clip^(val*%OVL_BRIGHTFIX%,0,255^):g=clip^(val*%OVL_BRIGHTFIX%,0,255^):b=clip^(val*%OVL_BRIGHTFIX%,0,255^)'^"^
	-c:a copy -c:v libx264rgb -crf 0 TMPstep03.avi
)

if errorlevel 1 exit /b


::+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++::
:: Detect crop area; crop, rescale, add vignette, pad, set sar/dar ::
::+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++::

ffmpeg -hide_banner -y -f lavfi ^
	-i ^"color=c=#ffffff:s=%PX%x%PY%^"^
	-vf ^"format=rgb24 %LENSC%, cropdetect=limit=0:round=2^"^
	-frames:v 3 -f null - 2>&1 ^
| find ^"crop^" > TMPcrop
if errorlevel 1 exit /b

for /f "tokens=*" %%a IN (TMPcrop) do set CROPTEMP=%%a
for %%a IN (%CROPTEMP%) do set CROP_STR=%%a

ffmpeg -hide_banner -y -i TMPstep03.avi -vf ^"^
	crop=%CROP_STR%,^
	lutrgb='r=gammaval(2.2):g=gammaval(2.2):b=gammaval(2.2)',^
	scale=w=%OX%-%OMARGIN%*2:h=%OY%-%OMARGIN%*2:force_original_aspect_ratio=decrease:flags=%OFILTER%+%SWSFLAGS%,^
	lutrgb='r=gammaval(0.454545):g=gammaval(0.454545):b=gammaval(0.454545)',^
	setsar=sar=1/1,^
	%VIGNETTE_STR%^
	pad=%OX%:%OY%:-1:-1:black^" ^
-c:a copy -c:v libx264rgb -crf 8 "%OUTFILE%"
if errorlevel 1 exit /b

::++++++++++::
:: Clean up ::
::++++++++++::

del TMP*
@echo. & echo ------------------------
@echo Output file: %OUTFILE%
@echo Started:     %FFSTART%
@echo Finished:    %time%
@echo.