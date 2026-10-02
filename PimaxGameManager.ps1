# Pimax Game Manager - library images, library order, per-game settings and performance for Pimax Play
# -Guard starts the Performance Guard (tray icon) instead of the window
param([switch]$Test, [switch]$Guard)

# --- Run as admin (needed to restart the Pimax service) ---
if (-not $Test -and -not $Guard) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        exit
    }
}

if (-not $Guard) { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PimaxDir    = Join-Path $env:APPDATA 'Pimax'
$ManifestDir = Join-Path $PimaxDir 'manifest'
# The app's own data lives outside Pimax's folder so a Pimax update can't wipe it
$DataDir     = Join-Path $env:APPDATA 'PimaxGameManager'
$CoverDir    = Join-Path $DataDir 'covers'
$BackupDir   = Join-Path $DataDir 'backups'
$SnapshotDir = Join-Path $DataDir 'snapshots'
$LegacyBackupDir = Join-Path $PimaxDir 'cover-backups'
$ServiceName = 'PiServiceLauncher'
$DefaultClient = 'C:\Program Files\Pimax\PimaxClient\pimaxui\PimaxClient.exe'
foreach ($d in $DataDir, $CoverDir, $BackupDir, $SnapshotDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
# One-time carry-over from older versions (copies only; nothing is deleted)
try {
    if (Test-Path $LegacyBackupDir) {
        foreach ($f in Get-ChildItem $LegacyBackupDir -Recurse -File) {
            $dst = Join-Path $BackupDir $f.FullName.Substring($LegacyBackupDir.Length).TrimStart('\')
            if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null; Copy-Item -LiteralPath $f.FullName $dst }
        }
    }
    $legacyCfg = Join-Path $PimaxDir 'cover-changer-settings.json'; $newCfg = Join-Path $DataDir 'settings.json'
    if ((Test-Path $legacyCfg) -and -not (Test-Path $newCfg)) { Copy-Item $legacyCfg $newCfg }
} catch { }
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$AppVersion = '1.9.2'
$RepoApi = 'https://api.github.com/repos/SFXShannon/pimax-game-manager/releases/latest'

# ---------- Performance: lock game settings, performance cores, window fix, background guard ----------
# Some games (American Truck Simulator, MSFS...) keep their graphics settings in their own file and
# rewrite it when they quit or update. "Performance" remembers the values you want and puts them back
# while the game is closed, runs the game on the CPU's performance cores and keeps its desktop window
# on screen. The background part (the Performance Guard) is this same app started with -Guard; it runs
# at logon from a scheduled task, so it needs no admin prompt, and shows a tray icon.
$PerfFile      = Join-Path $DataDir 'performance.json'
$PerfLog       = Join-Path $DataDir 'performance.log'
$PerfBackupDir = Join-Path $BackupDir 'performance'
$GuardTask     = 'Pimax Game Manager Performance Guard'
$GuardMutex    = 'Global\PimaxGameManagerPerformanceGuard'
$PerfInv       = [Globalization.CultureInfo]::InvariantCulture

function New-PerfSetting([string]$key, [string]$label, [string]$group, $rec, [string]$tip) {
    [pscustomobject]@{ Key = $key; Label = $label; Group = $group; Recommended = $rec; Tip = $tip }
}

# Settings shown for the SCS engine games (American Truck Simulator, Euro Truck Simulator 2): config.cfg, lines like  uset r_ssao "2"
$ScsSettings = @(
    New-PerfSetting 'r_scale_x' 'Scaling (width)' 'Resolution & timing' '1' 'In-game resolution scaling. In VR it multiplies the headset resolution, so 1 = exactly what the headset asks for.'
    New-PerfSetting 'r_scale_y' 'Scaling (height)' 'Resolution & timing' '1' 'Should match the width. A different value stretches the render and costs GPU time.'
    New-PerfSetting 't_ignore_hmd_timing' 'Ignore headset timing (1 = yes)' 'Resolution & timing' '0' '0 lets the headset pace the frames, which avoids judder in VR.'
    New-PerfSetting 't_limit_fps' 'Frame rate limit (0 = off)' 'Resolution & timing' '0' 'In VR the headset sets the frame rate, so the game''s own limiter is best off.'
    New-PerfSetting 't_limit_fps_inactive' 'Frame rate limit when not focused (0 = off)' 'Resolution & timing' '0' 'The game drops to this frame rate when its desktop window is not the active window.'
    New-PerfSetting 'r_ssao' 'Ambient occlusion (0-2)' 'Graphics (GPU)' '1' 'SSAO. 1 is much cheaper than 2 and hard to tell apart in VR.'
    New-PerfSetting 'r_sun_shadow_texture_size' 'Sun shadow size' 'Graphics (GPU)' '2048' '4096, 2048 or 1024.'
    New-PerfSetting 'r_cloud_shadows' 'Cloud shadows (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'r_far_shadow_disable' 'Far shadows off (1 = off)' 'Graphics (GPU)' '1' 'Also saves CPU time.'
    New-PerfSetting 'g_reflection' 'Reflections (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'g_rain_reflection' 'Rain reflections (1 = on)' 'Graphics (GPU)' '0' 'Only costs anything in rain, but then it causes frame drops.'
    New-PerfSetting 'r_anisotropy_factor' 'Texture filtering (0-1)' 'Graphics (GPU)' '1' 'Sharper roads in the distance for almost no cost.'
    New-PerfSetting 'r_mirror_view_distance' 'Mirror view distance' 'World detail (CPU)' '150' 'Every mirror draws the world again on the main thread - the biggest CPU cost in cities.'
    New-PerfSetting 'g_traffic' 'Traffic density' 'World detail (CPU)' '0.5' ''
    New-PerfSetting 'g_lod_factor_traffic' 'Traffic detail distance' 'World detail (CPU)' '0.5' ''
    New-PerfSetting 'g_lod_factor_parked' 'Parked car detail distance' 'World detail (CPU)' '0.5' ''
    New-PerfSetting 'g_lod_factor_pedestrian' 'Pedestrian detail distance' 'World detail (CPU)' '0.5' ''
    New-PerfSetting 'g_grass_density' 'Grass density (0-2)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'g_veg_detail' 'Vegetation detail (0-2)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'r_mode_width' 'Desktop window width' 'Desktop window' '960' 'The mirror window on your monitor. Smaller is cheaper and easier to keep on screen.'
    New-PerfSetting 'r_mode_height' 'Desktop window height' 'Desktop window' '540' ''
)

# Settings shown for Microsoft Flight Simulator: UserCfg.opt, nested {Section ... } blocks. Only the VR settings are listed.
# No recommended value means "keep what you have" - Recommended for VR leaves those alone.
$MsfsSettings = @(
    New-PerfSetting 'Video/PrimaryScalingVR' 'Render scaling (VR)' 'Resolution & timing' $null '1.000000 = the headset resolution.'
    New-PerfSetting 'Video/AntiAliasingVR' 'Anti-aliasing (VR)' 'Resolution & timing' $null 'DLSS, TAA, FSR...'
    New-PerfSetting 'Video/DLSSModeVR' 'DLSS mode (VR)' 'Resolution & timing' $null 'QUALITY, BALANCED, PERFORMANCE, AUTO...'
    New-PerfSetting 'Video/DynamicSettingsVR' 'Dynamic settings (VR, 1 = on)' 'Resolution & timing' '0' 'When on, the sim changes settings on its own, which fights a locked setup.'
    New-PerfSetting 'GraphicsVR/Shadows/Size' 'Shadow map size' 'Graphics (GPU)' $null '768, 1024, 1536, 2048...'
    New-PerfSetting 'GraphicsVR/VolumetricClouds/Quality' 'Volumetric clouds (0-3)' 'Graphics (GPU)' '2' ''
    New-PerfSetting 'GraphicsVR/SSR/Enabled' 'Screen space reflections (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'GraphicsVR/SSAO/Quality' 'Ambient occlusion (0-3)' 'Graphics (GPU)' '1' ''
    New-PerfSetting 'GraphicsVR/Terrain/LoDFactor' 'Terrain level of detail' 'World detail (CPU)' '1.0' 'The biggest CPU setting in the sim. 1.0 is about "Medium/High".'
    New-PerfSetting 'GraphicsVR/ObjectsLoD/LoDFactor' 'Objects level of detail' 'World detail (CPU)' '1.0' ''
    New-PerfSetting 'GraphicsVR/Buildings/Quality' 'Buildings (0-3)' 'World detail (CPU)' '2' ''
    New-PerfSetting 'GraphicsVR/Procedural/TreesQuality' 'Trees (0-3)' 'World detail (CPU)' '2' ''
    New-PerfSetting 'GraphicsVR/Procedural/GrassQuality' 'Grass and bushes (0-3)' 'World detail (CPU)' '2' ''
    New-PerfSetting 'GraphicsVR/Characters/Quantity' 'People (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'GraphicsVR/Fauna/Quantity' 'Animals (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'GraphicsVR/Traffic/AircraftTrafficQuantity' 'Air traffic (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'GraphicsVR/Traffic/ParkedAircraftQuantity' 'Parked aircraft (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'GraphicsVR/Traffic/AirportsServicesQuantity' 'Airport vehicles (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'GraphicsVR/Traffic/RoadQuality' 'Road traffic (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'GraphicsVR/Traffic/SeaQuality' 'Boats (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'GraphicsVR/GlassCockpitsRefreshRate/Quality' 'Glass cockpit refresh rate (0-2)' 'World detail (CPU)' '1' 'Cockpit screens redraw on the main thread.'
)

# iRacing: the VR renderer has its own file, rendererDX11OpenXR.ini
$IRacingSettings = @(
    New-PerfSetting 'Graphics Options/LODMinFPSTarget' 'Lower detail when FPS drops below' 'Resolution & timing' '90' 'iRacing lowers level of detail on its own when the frame rate falls under this. Set it to your headset refresh rate.'
    New-PerfSetting 'Graphics Options/EnableHDR' 'HDR rendering (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'Graphics Options/SSAO' 'Ambient occlusion (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'Graphics Options/SSRLevel' 'Screen space reflections (0-2)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'Graphics Options/HeatHaze' 'Heat haze (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'Graphics Options/DepthOfField' 'Depth of field (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'Graphics Options/MotionBlurStrength' 'Motion blur (0-4)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'Graphics Options/ShadowDetail' 'Shadow detail (0 = fewer)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'Graphics Options/DynamicShadowRes' 'Car shadow resolution (0-4)' 'Graphics (GPU)' '1' ''
    New-PerfSetting 'Graphics Options/ShaderQuality' 'Shader quality (0-3)' 'Graphics (GPU)' $null ''
    New-PerfSetting 'Graphics Options/NumDynamicCubemaps' 'Dynamic reflections per frame' 'Graphics (GPU)' '0' 'Reflections on the car body. 0 is a big saving.'
    New-PerfSetting 'Graphics Options/MaxCarsToDraw' 'Cars drawn (10-64)' 'World detail (CPU)' '20' 'The biggest CPU setting in iRacing.'
    New-PerfSetting 'Graphics Options/MaxCarsToDrawInMirrors' 'Cars drawn in mirrors (4-64)' 'World detail (CPU)' '8' ''
    New-PerfSetting 'Graphics Options/MaxCockpitMirrors' 'Cockpit mirrors (0-4)' 'World detail (CPU)' $null 'Each mirror draws the scene again. Fewer is faster.'
    New-PerfSetting 'Graphics Options/MirrorDetail' 'Mirror detail (1 = high)' 'World detail (CPU)' '0' ''
    New-PerfSetting 'Graphics Options/ObjectDetail' 'Object population (0-2)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'Graphics Options/CrowdDetail' 'Crowd (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'Graphics Options/GrandstandDetail' 'Grandstands (0-2)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'Graphics Options/PitObjectDetail' 'Pit objects (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'Graphics Options/FoliageDetail' 'Foliage (0-3)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'Graphics Options/ParticleDetail' 'Particles (0-2)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'Graphics Options/WeekendDetail' 'Event detail (0-2)' 'World detail (CPU)' '1' ''
)

# Assetto Corsa: cfg\video.ini (Content Manager also writes this file - lock only what you want to keep)
$AcSettings = @(
    New-PerfSetting 'VIDEO/AASAMPLES' 'Anti-aliasing samples (MSAA)' 'Graphics (GPU)' '2' 'Each step doubles the cost in VR. 2 or 4.'
    New-PerfSetting 'VIDEO/SHADOW_MAP_SIZE' 'Shadow resolution' 'Graphics (GPU)' '2048' '1024, 2048 or 4096.'
    New-PerfSetting 'VIDEO/ANISOTROPIC' 'Texture filtering' 'Graphics (GPU)' $null '0, 2, 4, 8 or 16.'
    New-PerfSetting 'POST_PROCESS/ENABLED' 'Post processing (1 = on)' 'Graphics (GPU)' $null ''
    New-PerfSetting 'POST_PROCESS/DOF' 'Depth of field (0-5)' 'Graphics (GPU)' '0' 'Blurs things in VR and costs GPU time.'
    New-PerfSetting 'POST_PROCESS/HEAT_SHIMMER' 'Heat shimmer (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'POST_PROCESS/GLARE' 'Glare (0-5)' 'Graphics (GPU)' $null ''
    New-PerfSetting 'CUBEMAP/FACES_PER_FRAME' 'Reflection faces per frame (0-6)' 'Graphics (GPU)' '1' 'Car reflections redrawn each frame. 1 is a big saving and still looks good.'
    New-PerfSetting 'CUBEMAP/SIZE' 'Reflection resolution' 'Graphics (GPU)' '512' ''
    New-PerfSetting 'EFFECTS/SMOKE' 'Smoke (0-5)' 'Graphics (GPU)' '2' ''
    New-PerfSetting 'EFFECTS/RENDER_SMOKE_IN_MIRROR' 'Smoke in mirrors (1 = on)' 'World detail (CPU)' '0' ''
    New-PerfSetting 'MIRROR/HQ' 'High quality mirrors (1 = on)' 'World detail (CPU)' '0' ''
    New-PerfSetting 'MIRROR/SIZE' 'Mirror resolution' 'World detail (CPU)' '512' ''
    New-PerfSetting 'ASSETTOCORSA/WORLD_DETAIL' 'World detail (0-5)' 'World detail (CPU)' '4' ''
)

# DCS World: Saved Games\DCS\Config\options.lua
$DcsSettings = @(
    New-PerfSetting 'VR/pixel_density' 'VR pixel density' 'Resolution & timing' $null '1.0 = the headset resolution. Leave at 1.0 if Pimax or OpenXR Toolkit sets the resolution.'
    New-PerfSetting 'graphics/MSAA' 'MSAA (0 = off)' 'Graphics (GPU)' $null 'MSAA is very expensive in VR; DLSS is usually the better choice.'
    New-PerfSetting 'graphics/shadows' 'Shadows (0-4)' 'Graphics (GPU)' '2' ''
    New-PerfSetting 'graphics/SSAO' 'SSAO (0 = off)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'graphics/SSLR' 'Screen space reflections (0 = off)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'graphics/DOF' 'Depth of field (0 = off)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'graphics/motionBlur' 'Motion blur (0 = off)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'graphics/LensEffects' 'Lens effects (0 = off)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'graphics/heatBlr' 'Heat blur (0 = off)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'graphics/clouds' 'Cloud quality' 'Graphics (GPU)' $null ''
    New-PerfSetting 'graphics/visibRange' 'Visible range' 'World detail (CPU)' 'Medium' 'Low, Medium, High, Ultra, Extreme.'
    New-PerfSetting 'graphics/clutterMaxDistance' 'Clutter / grass distance (0-1500)' 'World detail (CPU)' '400' ''
    New-PerfSetting 'graphics/forestDistanceFactor' 'Tree visibility (0.1-1)' 'World detail (CPU)' '0.5' ''
    New-PerfSetting 'graphics/forestDetailsFactor' 'Forest details (0.1-1)' 'World detail (CPU)' '0.5' ''
    New-PerfSetting 'graphics/sceneryDetailsFactor' 'Scenery details (0.1-1)' 'World detail (CPU)' $null ''
    New-PerfSetting 'graphics/civTraffic' 'Civilian traffic' 'World detail (CPU)' 'low' 'empty string = off, low, medium, high.'
    New-PerfSetting 'graphics/terrainTextures' 'Terrain textures' 'World detail (CPU)' $null 'min or max.'
    New-PerfSetting 'graphics/maxFPS' 'Frame rate limit' 'Resolution & timing' $null 'Used when the headset does not set the frame rate.'
)

# Automobilista 2: graphicsconfigdx11.xml (the game's own menu writes the same values)
$Ams2Settings = @(
    New-PerfSetting 'AntiAlias' 'Anti-aliasing (0 = off)' 'Graphics (GPU)' $null ''
    New-PerfSetting 'VRSuperSampling' 'VR supersampling (0 = off)' 'Graphics (GPU)' $null ''
    New-PerfSetting 'ShadowDetailLevel' 'Shadow detail (0 = low)' 'Graphics (GPU)' '1' ''
    New-PerfSetting 'EffectsDetailLevel' 'Effects detail (0 = low)' 'Graphics (GPU)' '1' ''
    New-PerfSetting 'EnvmapDetailLevel' 'Reflection map detail (0 = low)' 'Graphics (GPU)' '1' ''
    New-PerfSetting 'EnvmapReflectionDetailLevel' 'Reflection detail (0 = low)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'MotionblurLevel' 'Motion blur (0 = off)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'TextureResolution' 'Texture resolution' 'Graphics (GPU)' $null ''
    New-PerfSetting 'CarDetailLevel' 'Car detail (0 = low)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'TrackDetailLevel' 'Track detail (0 = low)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'MaxVisibleVehicles' 'Visible cars (setting step)' 'World detail (CPU)' $null 'The step picked in the menu (0 = fewest).'
    New-PerfSetting 'MirrorEnhanced' 'Enhanced mirror (1 = on)' 'World detail (CPU)' '0' ''
)

# RaceRoom: UserData\graphics_options.xml
$R3eSettings = @(
    New-PerfSetting 'multiSampleLevel' 'Anti-aliasing samples' 'Graphics (GPU)' '2' ''
    New-PerfSetting 'enableBloom' 'Bloom (true/false)' 'Graphics (GPU)' $null ''
    New-PerfSetting 'enableSunRays' 'Sun rays (true/false)' 'Graphics (GPU)' 'false' ''
    New-PerfSetting 'enableMotionBlur' 'Motion blur (true/false)' 'Graphics (GPU)' 'false' ''
    New-PerfSetting 'enableDof' 'Depth of field (true/false)' 'Graphics (GPU)' 'false' ''
    New-PerfSetting 'enableLensEffects' 'Lens effects (true/false)' 'Graphics (GPU)' 'false' ''
    New-PerfSetting 'allowDynamicReflections' 'Dynamic reflections (true/false)' 'Graphics (GPU)' 'false' ''
    New-PerfSetting 'shadowFilterDetail' 'Shadow filtering (0-4)' 'Graphics (GPU)' '2' ''
    New-PerfSetting 'overallDetailLevel' 'Overall detail (0-3)' 'World detail (CPU)' $null ''
    New-PerfSetting 'lodDetailLevel' 'Level of detail (0-2)' 'World detail (CPU)' '1' ''
    New-PerfSetting 'lodTrackLevel' 'Track detail (0-2)' 'World detail (CPU)' $null ''
    New-PerfSetting 'particleDetailLevel' 'Particles (0-2)' 'World detail (CPU)' '1' ''
)

# Falcon BMS: changes go in "Falcon BMS User.cfg", which BMS reads after "Falcon BMS.cfg" and an update never replaces
$BmsSettings = @(
    New-PerfSetting 'g_fVRResolution' 'VR resolution multiplier' 'Resolution & timing' $null '1.0 = the headset resolution.'
    New-PerfSetting 'g_bVRParallelRenderThread' 'Multi-threaded VR rendering (1 = on)' 'Resolution & timing' '1' 'Higher frame rate; 0 = lower latency.'
    New-PerfSetting 'g_nVRExternalRenderingMode' 'Outside world rendering (0-2)' 'Resolution & timing' $null '0 = mixed (stereo near the ground), 1 = always mono (fastest), 2 = always stereo.'
    New-PerfSetting 'g_bVRNoPresent' 'No desktop mirror window (1 = none)' 'Desktop window' $null 'Skips drawing the desktop window. Saves a little GPU time, but you will not see the sim on your monitor.'
    New-PerfSetting 'g_bNewTerrainRenderGrass' 'Grass (1 = on)' 'World detail (CPU)' '0' ''
    New-PerfSetting 'g_fNewTerrainProceduralDistance' 'Procedural terrain distance (km)' 'World detail (CPU)' '8.0' 'Heavy at low altitude. BMS default is 12.'
    New-PerfSetting 'g_nNewTerrainHiresTilesDistKM' 'High-res terrain distance (0, 16 or 32 km)' 'World detail (CPU)' $null ''
    New-PerfSetting 'g_bShadowOnSmoke' 'Shadows on smoke (1 = on)' 'Graphics (GPU)' '0' ''
    New-PerfSetting 'g_bEnvMapRenderClouds' 'Clouds in reflections (1 = on)' 'Graphics (GPU)' '0' ''
)
function Get-BmsUserCfg {
    $dirs = @()
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Benchmark Sims', 'HKLM:\SOFTWARE\Benchmark Sims') {
        foreach ($s in Get-ChildItem $k -ErrorAction SilentlyContinue) { $b = (Get-ItemProperty $s.PSPath -ErrorAction SilentlyContinue).baseDir; if ($b) { $dirs += $b } }
    }
    foreach ($dr in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) { $dirs += @(Get-ChildItem $dr.RootDirectory.FullName -Directory -Filter 'Falcon BMS*' -ErrorAction SilentlyContinue | ForEach-Object FullName) }
    foreach ($d in ($dirs | Select-Object -Unique)) { $f = Join-Path $d 'User\Config\Falcon BMS User.cfg'; if (Test-Path -LiteralPath $f) { return $f } }
}

$Docs = [Environment]::GetFolderPath('MyDocuments')
$PerfGames = @(
    [pscustomobject]@{ Id = 'ats'; Name = 'American Truck Simulator'; Process = 'amtrucks'; RouteMatch = '\\amtrucks\.exe|steam://\w+/270880\b'; Format = 'scs'; Settings = $ScsSettings
                       Configs = @(Join-Path $Docs 'American Truck Simulator\config.cfg') }
    [pscustomobject]@{ Id = 'ets2'; Name = 'Euro Truck Simulator 2'; Process = 'eurotrucks2'; RouteMatch = '\\eurotrucks2\.exe|steam://\w+/227300\b'; Format = 'scs'; Settings = $ScsSettings
                       Configs = @(Join-Path $Docs 'Euro Truck Simulator 2\config.cfg') }
    [pscustomobject]@{ Id = 'msfs2024'; Name = 'Microsoft Flight Simulator 2024'; Process = 'FlightSimulator2024'; RouteMatch = 'Microsoft Flight Simulator 2024\\|\\FlightSimulator2024\.exe|steam://\w+/2537590\b'; Format = 'msfs'; Settings = $MsfsSettings
                       Configs = @((Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt'),
                                   (Join-Path $env:APPDATA 'Microsoft Flight Simulator 2024\UserCfg.opt')) }
    [pscustomobject]@{ Id = 'msfs2020'; Name = 'Microsoft Flight Simulator 2020'; Process = 'FlightSimulator'; RouteMatch = 'Microsoft Flight Simulator\\Content\\|\\FlightSimulator\.exe|steam://\w+/1250410\b'; Format = 'msfs'; Settings = $MsfsSettings
                       Configs = @((Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt'),
                                   (Join-Path $env:APPDATA 'Microsoft Flight Simulator\UserCfg.opt')) }
    [pscustomobject]@{ Id = 'dcs'; Name = 'DCS World'; Process = 'DCS'; RouteMatch = '\\DCS\.exe|steam://\w+/223750\b|DCS World'; Format = 'lua'; Settings = $DcsSettings
                       Configs = @((Join-Path $env:USERPROFILE 'Saved Games\DCS\Config\options.lua'), (Join-Path $env:USERPROFILE 'Saved Games\DCS.openbeta\Config\options.lua')) }
    [pscustomobject]@{ Id = 'bms'; Name = 'Falcon BMS'; Process = 'Falcon BMS'; RouteMatch = 'Falcon BMS'; Format = 'bms'; Settings = $BmsSettings
                       Configs = @({ Get-BmsUserCfg }); BaseConfig = { param($p) Join-Path (Split-Path $p) 'Falcon BMS.cfg' } }
    [pscustomobject]@{ Id = 'iracing'; Name = 'iRacing (VR)'; Process = @('iRacingSim64DX11', 'iRacingSim64DX12'); RouteMatch = 'iRacing'; Format = 'ini'; Settings = $IRacingSettings
                       Configs = @(Join-Path $Docs 'iRacing\rendererDX11OpenXR.ini') }
    [pscustomobject]@{ Id = 'ac'; Name = 'Assetto Corsa'; Process = 'acs'; RouteMatch = '\\assettocorsa\\|\\acs\.exe|steam://\w+/244210\b'; Format = 'ini'; Settings = $AcSettings
                       Configs = @(Join-Path $Docs 'Assetto Corsa\cfg\video.ini') }
    [pscustomobject]@{ Id = 'ams2'; Name = 'Automobilista 2'; Process = @('AMS2AVX', 'AMS2'); RouteMatch = 'Automobilista 2|steam://\w+/1066890\b'; Format = 'xmlattr'; Settings = $Ams2Settings
                       Configs = @(Join-Path $Docs 'Automobilista 2\graphicsconfigdx11.xml') }
    [pscustomobject]@{ Id = 'r3e'; Name = 'RaceRoom Racing Experience'; Process = 'RRRE64'; RouteMatch = 'RaceRoom|steam://\w+/211500\b'; Format = 'xmltag'; Settings = $R3eSettings
                       Configs = @(Join-Path $Docs 'My Games\SimBin\RaceRoom Racing Experience\UserData\graphics_options.xml') }
)

function Get-PerfGame([string]$id) { $PerfGames | Where-Object { $_.Id -eq $id } | Select-Object -First 1 }
# Where a game keeps its settings file (some are found by a small search, done once per run)
$script:PerfPathCache = @{}
function Get-PerfConfigPath($pg) {
    if ($script:PerfPathCache.ContainsKey($pg.Id) -and $script:PerfPathCache[$pg.Id] -and (Test-Path -LiteralPath $script:PerfPathCache[$pg.Id])) { return $script:PerfPathCache[$pg.Id] }
    $found = $null
    foreach ($c in $pg.Configs) {
        $cand = if ($c -is [scriptblock]) { & $c } else { $c }
        if ($cand -and (Test-Path -LiteralPath $cand)) { $found = [string]$cand; break }
    }
    if ($found) { $script:PerfPathCache[$pg.Id] = $found }
    return $found
}

function Write-PerfLog([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}{2}" -f (Get-Date), $msg, [Environment]::NewLine
    try {
        [IO.File]::AppendAllText($PerfLog, $line, $Utf8NoBom)
        if ((New-Object IO.FileInfo $PerfLog).Length -gt 512KB) {
            $keep = [IO.File]::ReadAllLines($PerfLog); [IO.File]::WriteAllLines($PerfLog, [string[]]($keep | Select-Object -Last 2000), $Utf8NoBom)
        }
    } catch {
        try { [IO.File]::AppendAllText((Join-Path $env:TEMP "PimaxGameManager-performance.log"), "$line  (log error: $($_.Exception.Message))$([Environment]::NewLine)") } catch { }
    }
}

# performance.json: { guard: true/false, games: { <id>: { lock, values{key:value}, pinCores, keepWindow } } }
function Read-PerfConfig {
    $cfg = [pscustomobject]@{ guard = $false; games = [ordered]@{} }
    if (Test-Path -LiteralPath $PerfFile) {
        try {
            $j = [IO.File]::ReadAllText($PerfFile).TrimStart([char]0xFEFF) | ConvertFrom-Json
            $cfg.guard = [bool]$j.guard
            foreach ($p in @($j.games.PSObject.Properties)) {
                $vals = [ordered]@{}
                foreach ($v in @($p.Value.values.PSObject.Properties)) { $vals[$v.Name] = [string]$v.Value }
                $cfg.games[$p.Name] = [pscustomobject]@{ lock = [bool]$p.Value.lock; values = $vals; pinCores = [bool]$p.Value.pinCores; keepWindow = [bool]$p.Value.keepWindow }
            }
        } catch { Write-PerfLog "performance.json could not be read: $($_.Exception.Message)" }
    }
    return $cfg
}
function Save-PerfConfig($cfg) {
    $games = [ordered]@{}
    foreach ($k in $cfg.games.Keys) { $g = $cfg.games[$k]; $games[$k] = [ordered]@{ lock = [bool]$g.lock; pinCores = [bool]$g.pinCores; keepWindow = [bool]$g.keepWindow; values = $g.values } }
    $json = [ordered]@{ guard = [bool]$cfg.guard; games = $games } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($PerfFile, $json, $Utf8NoBom)
}
function Get-PerfEntry($cfg, [string]$id) {
    if (-not $cfg.games.Contains($id)) { $cfg.games[$id] = [pscustomobject]@{ lock = $false; values = [ordered]@{}; pinCores = $false; keepWindow = $false } }
    return $cfg.games[$id]
}

# Text of a game's config file, keeping its encoding and line endings when written back
function Read-TextKeep([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    [pscustomobject]@{ Text = $text; Bom = $bom; Nl = $(if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }) }
}
function Write-TextKeep([string]$path, $doc, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($doc.Bom))) }

# Settings files come in a few formats. Each line that holds a setting is split into
# Pre + Val + Post, so a value can be replaced without touching anything else on the line.
#   scs      uset r_ssao "2"                          (American / Euro Truck Simulator)
#   msfs     {Section ... Key value ... }             (Microsoft Flight Simulator UserCfg.opt)
#   ini      [Section] Key=Value ; comment            (iRacing, Assetto Corsa)
#   lua      ["section"] = { ["key"] = value, }       (DCS World options.lua)
#   xmlattr  <prop name="Key" key="value" />          (Automobilista 2)
#   xmltag   <key type="...">value</key>              (RaceRoom)
#   bms      set g_key value // comment               (Falcon BMS)
# Keys are Section/Key paths where the format has sections.
function Split-PerfLines($pg, [string]$text) {
    $stack = New-Object System.Collections.Generic.List[string]
    $lines = $text -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]; $t = $line.Trim(); $m = $null; $key = $null
        switch ($pg.Format) {
            'scs' { $m = [regex]::Match($line, '^(\s*uset\s+)(\S+)(\s+")([^"]*)(".*)$'); if ($m.Success) { $key = $m.Groups[2].Value; $pre = $m.Groups[1].Value + $key + $m.Groups[3].Value; $val = $m.Groups[4].Value; $post = $m.Groups[5].Value } }
            'msfs' {
                if ($t.StartsWith('{')) { $stack.Add($t.Substring(1).Trim()); continue }
                if ($t -eq '}') { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }; continue }
                $m = [regex]::Match($line, '^(\s*)(\S+)(\s+)(.*?)(\s*)$')
                if ($m.Success) { $key = (@($stack) + $m.Groups[2].Value) -join '/'; $pre = $m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value; $val = $m.Groups[4].Value; $post = $m.Groups[5].Value }
            }
            'ini' {
                $s = [regex]::Match($line, '^\s*\[(.+?)\]'); if ($s.Success) { $stack.Clear(); $stack.Add($s.Groups[1].Value); continue }
                $m = [regex]::Match($line, '^(\s*)([^=;#\[\s][^=]*?)(\s*=\s*)(.*?)(\s*(?:;.*)?)$')
                if ($m.Success) { $key = (@($stack) + $m.Groups[2].Value) -join '/'; $pre = $m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value; $val = $m.Groups[4].Value; $post = $m.Groups[5].Value }
            }
            'lua' {
                if ($t -match '^\["([^"]+)"\]\s*=\s*\{\s*$') { $stack.Add($Matches[1]); continue }
                if ($t -match '^\},?$') { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }; continue }
                $m = [regex]::Match($line, '^(\s*\["([^"]+)"\]\s*=\s*)(.*?)(,?\s*)$')
                if ($m.Success) { $key = (@($stack) + $m.Groups[2].Value) -join '/'; $pre = $m.Groups[1].Value; $val = $m.Groups[3].Value; $post = $m.Groups[4].Value }
            }
            'xmlattr' { $m = [regex]::Match($line, '^(\s*<prop name="([^"]+)" (?!type=)[A-Za-z_]+=")([^"]*)(".*)$'); if ($m.Success) { $key = $m.Groups[2].Value; $pre = $m.Groups[1].Value; $val = $m.Groups[3].Value; $post = $m.Groups[4].Value } }
            'xmltag' { $m = [regex]::Match($line, '^(\s*<([A-Za-z_][\w]*) type="[^"]*">)([^<]*)(</\2>.*)$'); if ($m.Success) { $key = $m.Groups[2].Value; $pre = $m.Groups[1].Value; $val = $m.Groups[3].Value; $post = $m.Groups[4].Value } }
            'bms' { $m = [regex]::Match($line, '^(\s*set\s+)(\S+)(\s+)(\S+)(.*)$'); if ($m.Success) { $key = $m.Groups[2].Value; $pre = $m.Groups[1].Value + $key + $m.Groups[3].Value; $val = $m.Groups[4].Value; $post = $m.Groups[5].Value } }
        }
        if ($key) { $out.Add([pscustomobject]@{ Index = $i; Key = $key; Pre = $pre; Val = $val; Post = $post }) }
    }
    return [pscustomobject]@{ Lines = $lines; Items = $out }
}

# DCS writes text values in quotes; they are shown and stored without them
function ConvertFrom-PerfRaw($pg, [string]$v) { if ($pg.Format -eq 'lua' -and $v -match '^"(.*)"$') { return $Matches[1] }; return $v }
function ConvertTo-PerfRaw($pg, [string]$v, [string]$old) {
    if ($pg.Format -eq 'lua' -and $old -match '^".*"$' -and $v -notmatch '^".*"$') { return '"' + $v + '"' }
    return $v
}

# All values in a game's config file, as key -> value. Falcon BMS also reads its main file under the user file.
function Read-PerfValues($pg, [string]$path) {
    $vals = @{}
    $files = @(); if ($pg.BaseConfig -and (Test-Path -LiteralPath (& $pg.BaseConfig $path))) { $files += (& $pg.BaseConfig $path) }; $files += $path
    foreach ($f in $files) {
        $p = Split-PerfLines $pg (Read-TextKeep $f).Text
        foreach ($it in $p.Items) { $vals[$it.Key] = (ConvertFrom-PerfRaw $pg $it.Val) }
    }
    return $vals
}

# Puts the wanted values into the file. Returns the changes made ("key old->new"); writes nothing if all match.
# Formats where a missing line is fine to add (the game reads it like any other) get it appended.
function Set-PerfValues($pg, [string]$path, $want, [switch]$WhatIf) {
    $doc = Read-TextKeep $path
    $p = Split-PerfLines $pg $doc.Text
    $lines = $p.Lines; $changes = New-Object System.Collections.Generic.List[string]; $seen = @{}
    foreach ($it in $p.Items) {
        if (-not $want.Contains($it.Key)) { continue }
        $seen[$it.Key] = $true
        $old = ConvertFrom-PerfRaw $pg $it.Val; $v = [string]$want[$it.Key]
        if ($old -ne $v) {
            $lines[$it.Index] = $it.Pre + (ConvertTo-PerfRaw $pg $v $it.Val) + $it.Post
            $changes.Add("$($it.Key) $old->$v")
        }
    }
    $text = $lines -join $doc.Nl
    if ($pg.Format -in 'scs', 'bms') {
        foreach ($k in @($want.Keys)) {
            if ($seen.ContainsKey($k)) { continue }
            $line = if ($pg.Format -eq 'scs') { "uset $k `"$($want[$k])`"" } else { "set $k $($want[$k])" }
            $changes.Add("$k (added) $($want[$k])"); $text = $text.TrimEnd("`r", "`n") + $doc.Nl + $line + $doc.Nl
        }
    }
    if ($changes.Count -and -not $WhatIf) {
        $dir = Join-Path $PerfBackupDir $pg.Id
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        if (-not (Get-PerfOriginal $pg)) { Copy-Item -LiteralPath $path (Join-Path $dir ('original-' + [IO.Path]::GetFileName($path))) }
        Copy-Item -LiteralPath $path (Join-Path $dir ("{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), [IO.Path]::GetFileName($path)))
        Get-ChildItem $dir -File | Where-Object { $_.Name -notlike 'original-*' } | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -ErrorAction SilentlyContinue
        Write-TextKeep $path $doc $text
    }
    return $changes.ToArray()      # callers wrap it in @() to count
}

# The game's file as it was before this app first changed it ("original-..."; for older backups, the oldest copy)
function Get-PerfOriginal($pg) {
    $dir = Join-Path $PerfBackupDir $pg.Id
    if (-not (Test-Path $dir)) { return $null }
    $o = Get-ChildItem $dir -File -Filter 'original-*' | Select-Object -First 1
    if (-not $o) { $o = Get-ChildItem $dir -File | Sort-Object Name | Select-Object -First 1 }   # names start with the date and time of the backup
    return $o
}

try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace PGMPerf {
  public static class Cpu {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetLogicalProcessorInformationEx(int rel, IntPtr buf, ref int len);
    // Logical processors of the fastest core type (Intel P-cores) as an affinity mask; 0 if all cores are the same
    public static long PerformanceCoreMask() {
      int len = 0; GetLogicalProcessorInformationEx(0, IntPtr.Zero, ref len);
      if (len <= 0) return 0;
      IntPtr buf = Marshal.AllocHGlobal(len);
      try {
        if (!GetLogicalProcessorInformationEx(0, buf, ref len)) return 0;
        long[] masks = new long[256]; int maxCls = -1, minCls = 256; int off = 0;
        while (off < len) {
          int size = Marshal.ReadInt32(buf, off + 4);
          int cls = Marshal.ReadByte(buf, off + 9);
          long mask = Marshal.ReadInt64(buf, off + 32);
          if (Marshal.ReadInt16(buf, off + 40) == 0) {           // GroupMask[0].Group == 0
            masks[cls] |= mask; if (cls > maxCls) maxCls = cls; if (cls < minCls) minCls = cls;
          }
          off += size;
        }
        return (maxCls > minCls) ? masks[maxCls] : 0;
      } finally { Marshal.FreeHGlobal(buf); }
    }
  }
  public static class Win {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static System.Collections.Generic.List<IntPtr> VisibleWindowsOf(uint pid) {
      var list = new System.Collections.Generic.List<IntPtr>();
      EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
      return list;
    }
  }
}
'@
} catch { }
function Get-PCoreMask { try { [long][PGMPerf.Cpu]::PerformanceCoreMask() } catch { 0L } }
function Get-PCoreText([long]$mask) {
    if (-not $mask) { return '' }
    $ids = for ($i = 0; $i -lt 64; $i++) { if ($mask -band ([long]1 -shl $i)) { $i } }
    "logical processors {0}-{1}" -f $ids[0], $ids[-1]
}

# Running copies of a game (ignores a half-closed leftover that no longer uses any memory)
function Get-PerfProcesses($pg) { @(Get-Process -Name $pg.Process -ErrorAction SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 50MB }) }

# Moves a game's desktop window back onto the screen if any part of it is outside the visible desktop
function Repair-GameWindow([int]$procId) {
    Add-Type -AssemblyName System.Windows.Forms
    $area = [Windows.Forms.SystemInformation]::VirtualScreen
    $moved = $false
    foreach ($h in [PGMPerf.Win]::VisibleWindowsOf([uint32]$procId)) {
        if ([PGMPerf.Win]::IsIconic($h)) { continue }
        $r = New-Object PGMPerf.Win+RECT; [void][PGMPerf.Win]::GetWindowRect($h, [ref]$r)
        if (($r.R - $r.L) -lt 200 -or ($r.B - $r.T) -lt 150) { continue }
        if ($r.L -lt $area.Left -or $r.T -lt $area.Top -or $r.R -gt $area.Right -or $r.B -gt $area.Bottom) {
            $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $w = [Math]::Min(960, $wa.Width - 80); $hgt = [Math]::Min(540, $wa.Height - 80)
            [void][PGMPerf.Win]::ShowWindow($h, 1)
            [void][PGMPerf.Win]::SetWindowPos($h, [IntPtr]::Zero, $wa.Left + 40, $wa.Top + 40, $w, $hgt, 0x0014)
            $moved = $true
        }
    }
    return $moved
}

# Locked settings for every game that is closed right now. Returns a short summary per game that changed.
function Invoke-PerfEnforce($cfg, [switch]$Force) {
    $out = @()
    foreach ($id in @($cfg.games.Keys)) {
        $e = $cfg.games[$id]; $pg = Get-PerfGame $id
        if (-not $pg -or -not $e.lock -or -not $e.values.Count) { continue }
        $path = Get-PerfConfigPath $pg
        if (-not $path) { continue }
        if ((Get-PerfProcesses $pg).Count) { continue }    # the game rewrites its file when it quits
        if (-not $Force -and ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalSeconds -lt 5) { continue }
        try {
            $ch = @(Set-PerfValues $pg $path $e.values)
            if ($ch.Count) { Write-PerfLog "$($pg.Name): put back $($ch.Count) setting(s): $($ch -join '; ')"; $out += [pscustomobject]@{ Game = $pg.Name; Count = $ch.Count } }
        } catch { Write-PerfLog "$($pg.Name): couldn't update $path - $($_.Exception.Message)" }
    }
    return $out
}

# ---- Performance Guard: start / stop / start with Windows ----
# How to start this app in guard mode: the exe with -Guard, or PowerShell running this script with -Guard
function Get-GuardLaunch {
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetFileNameWithoutExtension($exe) -ieq 'PimaxGameManager') { return [pscustomobject]@{ Exe = $exe; Args = '-Guard' } }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return [pscustomobject]@{ Exe = $ps; Args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Guard" }
}
function Test-GuardRunning {
    $m = $null
    try { if ([Threading.Mutex]::TryOpenExisting($GuardMutex, [ref]$m)) { $m.Dispose(); return $true } } catch [UnauthorizedAccessException] { return $true } catch { }
    return $false
}
# A scheduled task starts the guard at logon with the app's admin rights but without a prompt
function Register-GuardTask([bool]$atLogon) {
    $l = Get-GuardLaunch
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action    = New-ScheduledTaskAction -Execute $l.Exe -Argument $l.Args
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 7
    $task = Register-ScheduledTask -TaskName $GuardTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Keeps game settings locked and runs games on the performance cores (Pimax Game Manager).' -Force
    if (-not $atLogon) { [void](Disable-ScheduledTask -TaskName $GuardTask) }
    return $task
}
function Get-GuardTask { Get-ScheduledTask -TaskName $GuardTask -ErrorAction SilentlyContinue }
function Start-Guard {
    if (Test-GuardRunning) { return }
    $t = Get-GuardTask
    if (-not $t) { $t = Register-GuardTask $true }
    $wasDisabled = ($t.State -eq 'Disabled')
    if ($wasDisabled) { [void](Enable-ScheduledTask -TaskName $GuardTask) }
    Start-ScheduledTask -TaskName $GuardTask
    if ($wasDisabled) { Start-Sleep -Milliseconds 400; [void](Disable-ScheduledTask -TaskName $GuardTask) }
}
function Stop-Guard {
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='PimaxGameManager.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue) {
        if ($p.ProcessId -ne $PID -and $p.CommandLine -match '(?i)\s-Guard\b') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
# Keeps the scheduled task pointing at this copy of the app (after an update or if the exe was moved)
function Update-GuardTask {
    $t = Get-GuardTask
    if (-not $t) { return }
    $l = Get-GuardLaunch
    $a = $t.Actions | Select-Object -First 1
    if ($a.Execute -ne $l.Exe -or $a.Arguments -ne $l.Args) { [void](Register-GuardTask ($t.State -ne 'Disabled')) }
}

# ---- The guard itself: tray icon + a 3-second timer. Uses very little CPU; nothing runs while it waits. ----
function Start-PerfGuard {
    $script:gMutex = New-Object Threading.Mutex($false, $GuardMutex)
    $mine = $false
    try { $mine = $script:gMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mine = $true }   # a previous guard was ended without closing
    if (-not $mine) { return }                               # already running
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    Write-PerfLog "Performance Guard started (version $AppVersion)"

    $script:gPaused = $false; $script:gCfg = Read-PerfConfig; $script:gCfgTime = [datetime]::MinValue
    $script:gPinned = @{}; $script:gSeen = @{}; $script:gLastEnforce = [datetime]::MinValue
    $script:gMask = Get-PCoreMask

    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $icon = $null
    try { if ([IO.Path]::GetFileNameWithoutExtension($exe) -ieq 'PimaxGameManager') { $icon = [Drawing.Icon]::ExtractAssociatedIcon($exe) }
          elseif (Test-Path (Join-Path $PSScriptRoot 'PimaxGameManager.ico')) { $icon = New-Object Drawing.Icon (Join-Path $PSScriptRoot 'PimaxGameManager.ico') } } catch { }
    if (-not $icon) { $icon = [Drawing.SystemIcons]::Application }
    $script:gIconOn = $icon; $script:gIconOff = [Drawing.SystemIcons]::Warning

    $script:gTray = New-Object Windows.Forms.NotifyIcon
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $script:gHeader = New-Object Windows.Forms.ToolStripMenuItem('Performance Guard'); $script:gHeader.Enabled = $false
    [void]$menu.Items.Add($script:gHeader)
    $script:gGames = New-Object Windows.Forms.ToolStripMenuItem('Games')
    [void]$menu.Items.Add($script:gGames); [void]$menu.Items.Add('-')
    $script:gToggle = $menu.Items.Add('Pause')
    $miCheck = $menu.Items.Add('Put locked settings back now')
    $miApp   = $menu.Items.Add('Open Pimax Game Manager')
    $miLog   = $menu.Items.Add('Open log')
    [void]$menu.Items.Add('-')
    $miExit  = $menu.Items.Add('Exit (until next sign-in)')
    $script:gTray.ContextMenuStrip = $menu

    # Tray tooltips are cut off at 63 characters, so the tooltip gives a count and the menu lists each game
    $script:gUpdate = {
        $watched = @(foreach ($id in $script:gCfg.games.Keys) {
            $e = $script:gCfg.games[$id]; $pg = Get-PerfGame $id
            if (-not $pg) { continue }
            $what = @(); if ($e.lock -and $e.values.Count) { $what += "$($e.values.Count) settings locked" }; if ($e.pinCores) { $what += 'performance cores' }; if ($e.keepWindow) { $what += 'window on screen' }
            if ($what.Count) { [pscustomobject]@{ Name = $pg.Name; What = ($what -join ', ') } }
        })
        $state = if ($script:gPaused) { 'paused' } else { 'on' }
        $script:gTray.Icon = if ($script:gPaused) { $script:gIconOff } else { $script:gIconOn }
        $tip = "Performance Guard - $state - " + $(if ($watched.Count -eq 1) { $watched[0].Name } elseif ($watched.Count) { "$($watched.Count) games" } else { 'no games set up' })
        $script:gTray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
        $script:gGames.DropDownItems.Clear()
        $script:gGames.Text = $(if ($watched.Count) { "Games ($($watched.Count))" } else { 'Games (none set up)' })
        foreach ($w in ($watched | Sort-Object Name)) { $it = $script:gGames.DropDownItems.Add("$($w.Name): $($w.What)"); $it.Enabled = $false }
        if (-not $watched.Count) { $it = $script:gGames.DropDownItems.Add('Set games up in Pimax Game Manager > Performance'); $it.Enabled = $false }
        $script:gHeader.Text = "Performance Guard - $state"
        $script:gToggle.Text = if ($script:gPaused) { 'Resume' } else { 'Pause' }
    }
    $script:gToggle.add_Click({
        $script:gPaused = -not $script:gPaused; & $script:gUpdate
        Write-PerfLog $(if ($script:gPaused) { 'Paused from the tray' } else { 'Resumed from the tray' })
        $script:gTray.ShowBalloonTip(2500, 'Performance Guard', $(if ($script:gPaused) { 'Paused. Game settings will not be changed until you resume or sign in again.' } else { 'Running. Locked settings are kept.' }), 'Info')
    })
    $miCheck.add_Click({
        $script:gCfg = Read-PerfConfig
        $r = @(Invoke-PerfEnforce $script:gCfg -Force)
        $msg = if ($r.Count) { ($r | ForEach-Object { "$($_.Game): $($_.Count) setting(s) put back" }) -join "`n" } else { 'Everything already matches (games that are running are skipped).' }
        $script:gTray.ShowBalloonTip(3000, 'Performance Guard', $msg, 'Info')
    })
    $miApp.add_Click({
        $l = Get-GuardLaunch
        if ($l.Exe -like '*powershell.exe') { Start-Process $l.Exe -ArgumentList ($l.Args -replace '\s-Guard$', '') } else { Start-Process $l.Exe }
    })
    $miLog.add_Click({ if (-not (Test-Path $PerfLog)) { Write-PerfLog 'Log created' }; Start-Process notepad.exe $PerfLog })
    $miExit.add_Click({ Write-PerfLog 'Exited from the tray'; $script:gTimer.Stop(); $script:gTray.Visible = $false; [Windows.Forms.Application]::Exit() })
    $script:gTray.add_DoubleClick({ $miApp.PerformClick() })

    $script:gTimer = New-Object Windows.Forms.Timer
    $script:gTimer.Interval = 3000
    $script:gTimer.add_Tick({
        try {
            $t = if (Test-Path $PerfFile) { (Get-Item -LiteralPath $PerfFile).LastWriteTime } else { [datetime]::MinValue }
            if ($t -ne $script:gCfgTime) { $script:gCfg = Read-PerfConfig; $script:gCfgTime = $t; & $script:gUpdate }
            if ($script:gPaused) { return }
            foreach ($id in @($script:gCfg.games.Keys)) {
                $e = $script:gCfg.games[$id]; $pg = Get-PerfGame $id
                if (-not $pg) { continue }
                foreach ($p in (Get-PerfProcesses $pg)) {
                    if (-not $script:gPinned.ContainsKey($p.Id)) {
                        $script:gPinned[$p.Id] = $true; $script:gSeen[$p.Id] = Get-Date
                        if ($e.pinCores -and $script:gMask) {
                            try { $p.ProcessorAffinity = [IntPtr]$script:gMask; $p.PriorityClass = 'AboveNormal'; Write-PerfLog "$($pg.Name) started: running on the performance cores ($(Get-PCoreText $script:gMask)), priority above normal" }
                            catch { Write-PerfLog "$($pg.Name): couldn't set the cores - $($_.Exception.Message)" }
                        }
                    }
                    if ($e.keepWindow -and ((Get-Date) - $script:gSeen[$p.Id]).TotalMinutes -lt 5) {
                        try { if (Repair-GameWindow $p.Id) { Write-PerfLog "$($pg.Name): moved its desktop window back on screen" } } catch { }
                    }
                }
            }
            if (((Get-Date) - $script:gLastEnforce).TotalSeconds -ge 10) {
                $script:gLastEnforce = Get-Date
                $r = @(Invoke-PerfEnforce $script:gCfg)
                if ($r.Count) { $script:gTray.ShowBalloonTip(3000, 'Performance Guard', (($r | ForEach-Object { "$($_.Game): $($_.Count) setting(s) put back" }) -join "`n"), 'Info') }
            }
        } catch { Write-PerfLog "Guard error: $($_.Exception.Message)" }
    })

    & $script:gUpdate
    $script:gTray.Visible = $true
    $script:gTimer.Start()
    [Windows.Forms.Application]::Run()
    $script:gTray.Dispose()
    try { $script:gMutex.ReleaseMutex() } catch { }
}

# Started with -Guard: run the Performance Guard in the tray and nothing else
if ($Guard) {
    try { Start-PerfGuard } catch { Write-PerfLog "Performance Guard stopped after an error: $($_.Exception.Message)" }
    exit
}

# ---------- Library ----------
# -WithPending shows the library as it will be once the waiting changes are applied (see "Waiting changes" below)
function Get-PimaxGames([switch]$WithPending) {
    $games = @()
    foreach ($f in Get-ChildItem $ManifestDir -Filter *.json -ErrorAction SilentlyContinue) {
        try {
            $raw = [IO.File]::ReadAllText($f.FullName).TrimStart([char]0xFEFF)
            $j = $raw | ConvertFrom-Json
            $name = if ($j.name) { $j.name } elseif ($j.productName) { $j.productName } else { $f.BaseName }
            $src = switch ($j.source) { 'pimax_import' { 'Imported' } 'steam' { 'SteamVR' } 'oculus' { 'Oculus' } default { if ($j.source) { $j.source } else { 'Other' } } }
            $games += [pscustomobject]@{ Name = $name; Source = $src; Icon = $j.icon; File = $f.FullName; Route = $null; Pending = $null }
        } catch { }
    }
    if ($WithPending -and $script:Pending -and $script:Pending.Count) {
        $byFile = @{}; foreach ($g in $games) { $byFile[$g.File] = $g }
        foreach ($op in $script:Pending) {
            $g = $byFile[$op.File]
            switch ($op.Kind) {
                'add' {
                    $n = [pscustomobject]@{ Name = $op.Manifest.name; Source = 'Imported'; Icon = $op.Manifest.icon; File = $op.File; Route = $op.Manifest.route; Pending = 'new' }
                    $games += $n; $byFile[$op.File] = $n
                }
                'edit'         { if ($g) { $g.Name = $op.Name; $g.Route = $op.Route; $g.Pending = 'changed' } }
                'image'        { if ($g) { $g.Icon = $op.Icon; $g.Pending = 'changed' } }
                'restoreImage' { if ($g) { $g.Icon = $op.OrigIcon; $g.Pending = 'changed' } }
                'remove'       { if ($g) { $games = @($games | Where-Object { $_.File -ne $op.File }) } }
            }
        }
    }
    $games | Sort-Object @{ Expression = { if ($_.Source -eq 'Imported') { 0 } else { 1 } } }, Name
}

function Get-ClientPath {
    $p = Get-Process PimaxClient -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
    if ($p) { return $p.Path }
    return $DefaultClient
}

function Load-Bitmap([string]$source) {
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    if ($source -match '^https?://') {
        $bytes = (New-Object Net.WebClient).DownloadData($source)
        $bmp.StreamSource = New-Object IO.MemoryStream(,$bytes)
    } else {
        $bmp.StreamSource = New-Object IO.MemoryStream(,[IO.File]::ReadAllBytes($source))
    }
    $bmp.EndInit(); $bmp.Freeze()
    return $bmp
}

# ---------- Actions ----------
function Restart-Pimax {
    $client = Get-ClientPath
    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    # The library is held by PiPlayService.exe, which survives a plain service restart.
    # Stop the service, stop PiPlayService, then start the service; Pimax Play starts a fresh PiPlayService.
    $svcOk = $true
    try {
        Stop-Service $ServiceName -Force -ErrorAction Stop
        Get-Process PiPlayService -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Start-Service $ServiceName -ErrorAction Stop
    } catch {
        $svcOk = $false
        try { Start-Service $ServiceName -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 3
    if (Test-Path $client) { Start-Process $client }
    return $svcOk
}

function Save-Cover($game, [string]$source) {
    if ($game.Source -ne 'Imported') { throw "Pimax replaces images for $($game.Source) games every time it starts, so only imported games can have a custom image." }
    # The image is saved into the app's covers folder now; the game's entry is changed when the waiting changes are applied
    $id = [IO.Path]::GetFileNameWithoutExtension($game.File)
    $dest = Save-CoverFile $id $source
    Add-PendingChange ([pscustomobject]@{ Kind = 'image'; File = $game.File; Name = $game.Name; Icon = $dest })
    return $dest
}

function Get-OrigBackupPath($game) {
    foreach ($d in $BackupDir, $LegacyBackupDir) { $p = Join-Path $d ([IO.Path]::GetFileName($game.File) + '.orig'); if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

# Queues putting back the original image (only the image, so a rename or a new .exe made with Edit game is kept)
function Restore-Cover($game) {
    $queued = @($script:Pending | Where-Object { $_.File -eq $game.File -and $_.Kind -in 'image', 'add' })
    $backup = Get-OrigBackupPath $game
    if (-not $backup -and -not $queued.Count) { throw 'No backup for this game - it still has its original image.' }
    $icon = ''
    if ($backup) { try { $o = [IO.File]::ReadAllText($backup).TrimStart([char]0xFEFF) | ConvertFrom-Json; if ($o.icon) { $icon = [string]$o.icon } } catch { } }
    Add-PendingChange ([pscustomobject]@{ Kind = 'restoreImage'; File = $game.File; Name = $game.Name; OrigIcon = $icon })
}

# ---------- Image finder (Steam + SteamGridDB) ----------
$SettingsFile = Join-Path $DataDir 'settings.json'
function Get-AppSetting([string]$name) {
    try { return ([IO.File]::ReadAllText($SettingsFile) | ConvertFrom-Json).$name } catch { return $null }
}
function Set-AppSetting([string]$name, $value) {
    $o = [ordered]@{}
    try { $j = [IO.File]::ReadAllText($SettingsFile) | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $o[$p.Name] = $p.Value } } catch { }
    $o[$name] = $value
    [IO.File]::WriteAllText($SettingsFile, ([pscustomobject]$o | ConvertTo-Json), $Utf8NoBom)
}
function Get-SgdbKey { $k = Get-AppSetting 'sgdbKey'; if ($k) { return [string]$k }; return '' }
function Set-SgdbKey([string]$key) { Set-AppSetting 'sgdbKey' $key }

function Resolve-SteamAppId($game) {
    # A game still waiting to be added has no entry file yet; use the program it will start
    if (-not (Test-Path -LiteralPath $game.File)) { return (Resolve-SteamAppIdFromRoute (Get-Route $game)) }
    $j = [IO.File]::ReadAllText($game.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ([string]$j.id -match '^steam\.app\.(\d+)$') { return $Matches[1] }
    return (Resolve-SteamAppIdFromRoute ([string]$j.route))
}

# Steam app ID for an .exe or shortcut inside a Steam library (from Steam's appmanifest files)
function Resolve-SteamAppIdFromRoute([string]$route) {
    $info = Get-SteamInfoFromRoute $route
    if ($info) { return $info.AppId }
    return $null
}

function Get-SteamInfoFromRoute([string]$route) {
    if (-not $route) { return $null }
    if ($route -match '^steam://\w+/(\d+)') { return [pscustomobject]@{ AppId = $Matches[1]; Name = $null } }
    if ($route -like '*.lnk' -and (Test-Path -LiteralPath $route)) {
        try { $route = (New-Object -ComObject WScript.Shell).CreateShortcut($route).TargetPath } catch { }
    }
    if ($route -match '^(.*\\steamapps)\\common\\([^\\]+)') {
        $apps = $Matches[1]; $folder = $Matches[2]
        foreach ($acf in Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $txt = [IO.File]::ReadAllText($acf.FullName)
            if ($txt -match '"installdir"\s+"([^"]+)"' -and $Matches[1] -ieq $folder) {
                $name = if ($txt -match '"name"\s+"([^"]+)"') { ($Matches[1] -replace '[\u2122\u00AE\u00A9]', '').Trim() } else { $null }
                if ($txt -match '"appid"\s+"(\d+)"') { return [pscustomobject]@{ AppId = $Matches[1]; Name = $name } }
            }
        }
    }
    return $null
}

function New-Art([string]$label, [string]$thumb, [string]$url) { [pscustomobject]@{ Label = $label; Thumb = $thumb; Url = $url } }

function Get-SteamArt([string]$appId, [string]$name) {
    $base = "https://shared.steamstatic.com/store_item_assets/steam/apps/$appId"
    New-Art "$name - Steam banner" "$base/header.jpg" "$base/header.jpg"
    New-Art "$name - Steam capsule" "$base/capsule_616x353.jpg" "$base/capsule_616x353.jpg"
}

function Search-SteamStore([string]$term) {
    $r = Invoke-RestMethod -UseBasicParsing -Uri ("https://store.steampowered.com/api/storesearch/?term={0}&cc=us&l=english" -f [uri]::EscapeDataString($term))
    @($r.items) | Select-Object -First 5
}

function Invoke-Sgdb([string]$path) {
    Invoke-RestMethod -UseBasicParsing -Uri "https://www.steamgriddb.com/api/v2/$path" -Headers @{ Authorization = "Bearer $(Get-SgdbKey)" }
}

function Get-SgdbGrids([string]$kind, [string]$id, [string]$name, [int]$max) {
    $r = Invoke-Sgdb "grids/$kind/$id`?dimensions=460x215,920x430&types=static"
    @($r.data) | Select-Object -First $max | ForEach-Object {
        New-Art "$name - SteamGridDB $($_.width)x$($_.height)" $_.thumb $_.url
    }
}

function Find-Art($game, [string]$term, [bool]$exact) {
    $items = New-Object Collections.ArrayList
    $notes = @()
    $hasKey = [bool](Get-SgdbKey)
    $appId = if ($exact) { Resolve-SteamAppId $game } else { $null }
    if ($appId) {
        $notes += "Matched Steam app $appId."
        foreach ($a in Get-SteamArt $appId $game.Name) { [void]$items.Add($a) }
        if ($hasKey) {
            try { foreach ($a in Get-SgdbGrids 'steam' $appId $game.Name 30) { [void]$items.Add($a) } }
            catch { $notes += "SteamGridDB error: $($_.Exception.Message)" }
        }
    } else {
        try { foreach ($s in Search-SteamStore $term) { [void]$items.Add((Get-SteamArt ([string]$s.id) $s.name)[0]) } }
        catch { $notes += "Steam search failed: $($_.Exception.Message)" }
        if ($hasKey) {
            try {
                $found = @((Invoke-Sgdb ("search/autocomplete/{0}" -f [uri]::EscapeDataString($term))).data) | Select-Object -First 3
                foreach ($g in $found) { foreach ($a in Get-SgdbGrids 'game' ([string]$g.id) $g.name 10) { [void]$items.Add($a) } }
            } catch { $notes += "SteamGridDB error: $($_.Exception.Message)" }
        }
    }
    if (-not $hasKey) { $notes += 'Add a SteamGridDB key for many more choices.' }
    [pscustomobject]@{ Items = $items; Note = ($notes -join ' ') }
}

# ---------- Adding, editing and removing imported games ----------
# An imported game is one small file in Pimax's manifest folder, the same as Pimax's own Import makes:
# {"create_time":0,"icon":"","id":"local.xxxxxxxx","name":"...","play_time":0,"route":"<exe or shortcut>","source":"pimax_import","version":""}
$GameExeSkip = '^(unins\d*|uninstall.*|setup.*|.*installer.*|vc_?redist.*|vcredist.*|dxsetup|dotnet.*|ndp\d+.*|oalinst|physx.*|.*crash.*|.*report.*|.*helper.*|.*updater?|.*launcherpatcher.*|easyanticheat.*|eac.*setup.*|be(service|launcher).*|.*_be|unitycrashhandler.*|cefsharp.*|.*webhelper.*|zfgamebrowser|.*-cmd|.*server.*|hlds|hltv|srcds|vconsole.*|.*benchmark.*|.*editor.*|.*crs-.*)$'

function Get-RouteKey([string]$route) {
    if (-not $route) { return '' }
    try { return [IO.Path]::GetFullPath($route.Trim('"', ' ')).ToLower() } catch { return $route.Trim('"', ' ').ToLower() }
}

# Map of route -> game for everything already in the library (so the same game isn't added twice)
function Get-LibraryRoutes {
    $map = @{}
    foreach ($g in Get-PimaxGames -WithPending) { $r = Get-Route $g; if ($r) { $map[(Get-RouteKey $r)] = $g } }
    return $map
}

function New-ImportId {
    $taken = @{}; foreach ($f in Get-ChildItem $ManifestDir -Filter *.json -ErrorAction SilentlyContinue) { $taken[$f.BaseName] = $true }
    foreach ($o in @($script:Pending)) { $taken[[IO.Path]::GetFileNameWithoutExtension($o.File)] = $true }
    do { $id = 'local.' + (-join (1..8 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })) } while ($taken.ContainsKey($id))
    return $id
}

# A sensible display name for an .exe or shortcut
function Get-GameNameFromPath([string]$path) {
    $steam = Get-SteamInfoFromRoute $path
    if ($steam -and $steam.Name) { return $steam.Name }
    if ($path -like '*.lnk') { return [IO.Path]::GetFileNameWithoutExtension($path) }
    try {
        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        foreach ($n in $vi.ProductName, $vi.FileDescription) {
            $n = ([string]$n).Trim()
            if ($n -and $n -notmatch '^(Unreal Engine|Unity|UnrealGame|Game|Launcher|Microsoft|Windows)\b' -and $n.Length -le 60) { return $n }
        }
    } catch { }
    return ([IO.Path]::GetFileNameWithoutExtension($path) -replace '-Win64-Shipping$|-Shipping$', '')
}

# Finds the main .exe of each game under a folder: a Steam library, a games folder, or one game's folder
function Find-GameExes([string]$folder) {
    $folder = $folder.TrimEnd('\')
    $common = Join-Path $folder 'steamapps\common'
    $roots = if (Test-Path -LiteralPath $common) { @(Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue) }
             elseif (@(Get-ChildItem -LiteralPath $folder -Filter *.exe -File -ErrorAction SilentlyContinue).Count) { @(Get-Item -LiteralPath $folder) }
             else { @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue) }
    foreach ($root in $roots) {
        if ($root.Name -match '^(Steamworks Shared|SteamVR|Steam Controller Configs|_CommonRedist|CommonRedist|Redist|DirectX)$') { continue }
        $exes = @(Get-ChildItem -LiteralPath $root.FullName -Filter *.exe -File -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.BaseName -notmatch $GameExeSkip -and $_.FullName -notmatch '\\(_?CommonRedist|Redist|redistributables?|DirectX|Support|Installers?|Engine\\Binaries\\ThirdParty|__Installer)\\' -and $_.Length -gt 30KB })
        if (-not $exes.Count) { continue }
        $key = ($root.Name -replace '[^a-z0-9]', '').ToLower()
        # Prefer an exe named like its folder, then the shallowest, then the largest
        $best = $exes | Sort-Object @{ Expression = { $b = ($_.BaseName -replace '[^a-z0-9]', '').ToLower(); if ($key -and ($b -eq $key -or ($key.Length -ge 4 -and $b.Length -ge 3 -and ($b.StartsWith($key) -or $key.StartsWith($b))))) { 0 } else { 1 } } },
                                    @{ Expression = { ($_.FullName.Substring($root.FullName.Length) -split '\\').Count } },
                                    @{ Expression = { $_.Length }; Descending = $true } | Select-Object -First 1
        # Name: Steam's own name if it's a Steam game, else the game's folder name, else from the exe
        $steam = Get-SteamInfoFromRoute $best.FullName
        $name = if ($steam -and $steam.Name) { $steam.Name } elseif ($root.FullName -ne $folder) { $root.Name } else { Get-GameNameFromPath $best.FullName }
        [pscustomobject]@{ Name = $name; Route = $best.FullName; Others = @($exes | Where-Object { $_.FullName -ne $best.FullName } | ForEach-Object FullName) }
    }
}

# Picks a cover automatically: Steam's banner when the game is in a Steam library, otherwise an exact Steam
# store name match, otherwise the first SteamGridDB result (with a key). Returns an image URL or $null.
function Find-AutoCover([string]$name, [string]$route) {
    $appId = Resolve-SteamAppIdFromRoute $route
    if ($appId) { return (Get-SteamArt $appId $name | Select-Object -First 1).Url }
    $norm = { param($s) ([string]$s -replace '[^a-z0-9]', '').ToLower() }
    try {
        $hit = @(Search-SteamStore $name) | Where-Object { (& $norm $_.name) -eq (& $norm $name) } | Select-Object -First 1
        if ($hit) { return (Get-SteamArt ([string]$hit.id) $hit.name | Select-Object -First 1).Url }
    } catch { }
    if (Get-SgdbKey) {
        try {
            $g = @((Invoke-Sgdb ("search/autocomplete/{0}" -f [uri]::EscapeDataString($name))).data) | Select-Object -First 1
            if ($g) { $a = Get-SgdbGrids 'game' ([string]$g.id) $g.name 1 | Select-Object -First 1; if ($a) { return $a.Url } }
        } catch { }
    }
    return $null
}

# Saves an image (link or file) into the app's covers folder and returns the local path
function Save-CoverFile([string]$id, [string]$source) {
    $ext = [IO.Path]::GetExtension(($source -split '\?')[0]).ToLower()
    if ($ext -notin '.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif') { $ext = '.jpg' }
    $dest = Join-Path $CoverDir ("{0}_{1}{2}" -f $id, (Get-Date -Format 'yyyyMMddHHmmss'), $ext)
    if ($source -match '^https?://') { (New-Object Net.WebClient).DownloadFile($source, $dest) }
    else { Copy-Item -LiteralPath $source -Destination $dest -Force }
    try { Load-Bitmap $dest | Out-Null } catch { Remove-Item $dest -Force -ErrorAction SilentlyContinue; throw "That file isn't a readable image." }
    return $dest
}

function Write-Manifest([string]$path, $obj) {
    $text = $obj | ConvertTo-Json -Compress -Depth 10
    $null = $text | ConvertFrom-Json   # validate before writing
    [IO.File]::WriteAllText($path, $text, $Utf8NoBom)
}

# Adds games to the library. Each entry: Name, Route, and optionally Image (a link or file).
# Images are fetched now; the games are queued as waiting changes and written when they're applied. Returns a report.
function Add-ImportedGames($entries) {
    $have = Get-LibraryRoutes
    $report = [ordered]@{ Added = @(); Skipped = @(); ImageFailed = @() }
    foreach ($e in $entries) {
        $name = ([string]$e.Name).Trim(); $route = ([string]$e.Route).Trim('"', ' ')
        if (-not $name -or -not $route) { $report.Skipped += "$name (missing name or path)"; continue }
        if (-not (Test-Path -LiteralPath $route)) { $report.Skipped += "$name (file not found)"; continue }
        $k = Get-RouteKey $route
        if ($have.ContainsKey($k)) { $report.Skipped += "$name (already in your library as $($have[$k].Name))"; continue }
        $have[$k] = [pscustomobject]@{ Name = $name }
        $id = New-ImportId
        $icon = ''
        if ($e.Image) { try { $icon = Save-CoverFile $id ([string]$e.Image) } catch { $report.ImageFailed += $name } }
        $m = [pscustomobject][ordered]@{ create_time = 0; icon = $icon; id = $id; name = $name; play_time = 0; route = $route; source = 'pimax_import'; version = '' }
        Add-PendingChange ([pscustomobject]@{ Kind = 'add'; File = (Join-Path $ManifestDir "$id.json"); Name = $name; Manifest = $m })
        $report.Added += [pscustomobject]@{ Id = $id; Name = $name; HasImage = [bool]$icon }
    }
    return [pscustomobject]$report
}

# Renames an imported game or points it at a different .exe / shortcut (queued)
function Set-ImportedGame($game, [string]$name, [string]$route) {
    if ($game.Source -ne 'Imported') { throw 'Only imported games can be edited here; Pimax rebuilds Steam and Oculus entries itself.' }
    $name = $name.Trim(); $route = $route.Trim('"', ' ')
    if (-not $name) { throw 'The name is empty.' }
    if (-not (Test-Path -LiteralPath $route)) { throw "File not found: $route" }
    $k = Get-RouteKey $route
    $other = (Get-LibraryRoutes)[$k]
    if ($other -and $other.File -ne $game.File) { throw "That file is already in your library as $($other.Name)." }
    Add-PendingChange ([pscustomobject]@{ Kind = 'edit'; File = $game.File; Name = $name; Route = $route; OldName = $game.Name })
}

# Removes imported games from the library (queued). When applied, the entry files are moved to the app's backups
# folder (not deleted) and taken off the pinned list. Per-game settings are left for "Remove leftover settings".
function Remove-ImportedGames($games) {
    $games = @($games | Where-Object { $_.Source -eq 'Imported' })
    foreach ($g in $games) { Add-PendingChange ([pscustomobject]@{ Kind = 'remove'; File = $g.File; Name = $g.Name; Id = (Get-GameId $g) }) }
    return [pscustomobject]@{ Removed = $games.Count }
}

# ---------- Waiting changes ----------
# Changes to the library (added, edited and removed games, images) are queued here instead of restarting Pimax Play
# for each one. They're written in one go, while Pimax is stopped, by Invoke-WhilePimaxStopped - so they're also
# applied by any other save that restarts Pimax (library order, game settings, restoring a backup, Restart Pimax Play).
$script:Pending = New-Object Collections.ArrayList
$script:ApplyErrors = @()

function Add-PendingChange($op) {
    $add = $script:Pending | Where-Object { $_.File -eq $op.File -and $_.Kind -eq 'add' } | Select-Object -First 1
    if ($add) {
        # A game that is itself still waiting to be added: change what will be added instead
        switch ($op.Kind) {
            'edit'         { $add.Manifest.name = $op.Name; $add.Manifest.route = $op.Route; $add.Name = $op.Name }
            'image'        { $add.Manifest.icon = $op.Icon }
            'restoreImage' { $add.Manifest.icon = '' }
            'remove'       { [void]$script:Pending.Remove($add) }
        }
        return
    }
    $replaces = switch ($op.Kind) { 'remove' { 'edit', 'image', 'restoreImage' } 'image' { 'image', 'restoreImage' } 'restoreImage' { 'image', 'restoreImage' } 'edit' { 'edit' } default { @() } }
    $hadImage = $false
    foreach ($o in @($script:Pending | Where-Object { $_.File -eq $op.File })) {
        if ($replaces -contains $o.Kind) { if ($o.Kind -eq 'image') { $hadImage = $true }; [void]$script:Pending.Remove($o) }
    }
    # Undoing a waiting image on a game that never had a custom one: nothing left to do
    if ($op.Kind -eq 'restoreImage' -and $hadImage -and -not (Get-OrigBackupPath $op)) { return }
    if ($op.Kind -eq 'edit' -and $op.OldName) {
        $cur = [IO.File]::ReadAllText($op.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
        if ($cur.name -eq $op.Name -and (Get-RouteKey ([string]$cur.route)) -eq (Get-RouteKey $op.Route)) { return }   # edited back to how it is
    }
    [void]$script:Pending.Add($op)
}

function Get-PendingLabel($op) {
    switch ($op.Kind) {
        'add'          { "Add $($op.Name)" }
        'edit'         { if ($op.OldName -and $op.OldName -ne $op.Name) { "Rename $($op.OldName) to $($op.Name)" } else { "Change the program for $($op.Name)" } }
        'image'        { "New image for $($op.Name)" }
        'restoreImage' { "Original image for $($op.Name)" }
        'remove'       { "Remove $($op.Name)" }
    }
}

# Writes the waiting changes. Pimax must be stopped (Invoke-WhilePimaxStopped calls this). Each change is tried on
# its own; any that fail are listed in $script:ApplyErrors and stay waiting.
function Write-PendingChanges {
    $script:ApplyErrors = @()
    $script:LastApplied = 0
    foreach ($op in @($script:Pending)) {
        try {
            switch ($op.Kind) {
                'add' {
                    if (-not (Test-Path $ManifestDir)) { New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null }
                    Write-Manifest $op.File $op.Manifest
                }
                'edit' {
                    $dir = Join-Path $BackupDir 'edited-games'
                    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    Copy-Item -LiteralPath $op.File (Join-Path $dir ("{0}_{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), [IO.Path]::GetFileName($op.File)))
                    $j = [IO.File]::ReadAllText($op.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
                    $j.name = $op.Name
                    if ($j.PSObject.Properties.Name -contains 'route') { $j.route = $op.Route } else { $j | Add-Member -NotePropertyName route -NotePropertyValue $op.Route }
                    Write-Manifest $op.File $j
                }
                'image' {
                    $backup = Join-Path $BackupDir ([IO.Path]::GetFileName($op.File) + '.orig')
                    if (-not (Get-OrigBackupPath $op)) { Copy-Item -LiteralPath $op.File $backup }
                    $j = [IO.File]::ReadAllText($op.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
                    if ($j.PSObject.Properties.Name -contains 'icon') { $j.icon = $op.Icon } else { $j | Add-Member -NotePropertyName icon -NotePropertyValue $op.Icon }
                    Write-Manifest $op.File $j
                }
                'restoreImage' {
                    $backup = Get-OrigBackupPath $op
                    $j = [IO.File]::ReadAllText($op.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
                    if ($j.PSObject.Properties.Name -contains 'icon') { $j.icon = $op.OrigIcon } else { $j | Add-Member -NotePropertyName icon -NotePropertyValue $op.OrigIcon }
                    Write-Manifest $op.File $j
                    if ($backup) { Remove-Item -LiteralPath $backup -Force }
                }
                'remove' {
                    $dest = Join-Path $BackupDir 'removed-games'
                    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                    Move-Item -LiteralPath $op.File -Destination (Join-Path $dest ("{0}_{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), [IO.Path]::GetFileName($op.File))) -Force
                    if (Test-Path $ClientConfig) {
                        $text = [IO.File]::ReadAllText($ClientConfig)
                        $pins = @(Get-PinnedIds $text)
                        $keep = @($pins | Where-Object { $_ -ne $op.Id })
                        if ($keep.Count -ne $pins.Count) { [IO.File]::WriteAllText($ClientConfig, (Set-PinnedIdsInText $text $keep), $Utf8NoBom) }
                    }
                }
            }
            [void]$script:Pending.Remove($op)
            $script:LastApplied++
        } catch { $script:ApplyErrors += "$(Get-PendingLabel $op): $($_.Exception.Message)" }
    }
}

# IDs of games waiting to be removed (so the library order doesn't pin them again)
function Get-PendingRemovedIds { @($script:Pending | Where-Object { $_.Kind -eq 'remove' } | ForEach-Object { $_.Id }) }

# ---------- Library order (Pimax "pin to top" list) ----------
$ClientConfig = Join-Path $env:APPDATA 'PimaxClient\config.json'

function Get-PinnedIds([string]$text) {
    if (-not $text) { if (-not (Test-Path $ClientConfig)) { return @() }; $text = [IO.File]::ReadAllText($ClientConfig) }
    $m = [regex]::Match($text, '"pinToTopGameArray"\s*:\s*\[([^\]]*)\]')
    if (-not $m.Success) { return @() }
    @([regex]::Matches($m.Groups[1].Value, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
}

function Get-GameId($game) {
    try { $j = [IO.File]::ReadAllText($game.File).TrimStart([char]0xFEFF) | ConvertFrom-Json; if ($j.id) { return [string]$j.id } } catch { }
    return [IO.Path]::GetFileNameWithoutExtension($game.File)
}

# Approximates Pimax's own order: Steam by app ID, then other stores, then imports in the order added
function Get-PimaxOrderKey($game, [string]$id) {
    if ($id -match '^steam\.app\.(\d+)$') { return '1-{0:D12}' -f [long]$Matches[1] }
    if ($game.Source -ne 'Imported') { return '2-' + $game.Name }
    if (-not (Test-Path -LiteralPath $game.File)) { return '4-' + $game.Name }   # waiting to be added: goes in last
    return '3-' + (Get-Item -LiteralPath $game.File).CreationTime.ToString('yyyyMMddHHmmss')
}

function Save-PinnedOrder([string[]]$ids) {
    if (-not (Test-Path $ClientConfig)) { throw "Pimax Play settings file not found: $ClientConfig" }
    $backup = Join-Path $BackupDir 'PimaxClient-config.json.orig'
    if (-not (Test-Path $backup)) { Copy-Item $ClientConfig $backup }
    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $text = Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) $ids
    [IO.File]::WriteAllText($ClientConfig, $text, $Utf8NoBom)
}

function Set-PinnedIdsInText([string]$text, [string[]]$ids) {
    $esc = @($ids | ForEach-Object { '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"' })
    $arr = if ($esc.Count) { "[`n`t`t" + ($esc -join ",`n`t`t") + "`n`t]" } else { '[]' }
    $new = '"pinToTopGameArray": ' + $arr
    $rx = [regex]'"pinToTopGameArray"\s*:\s*\[[^\]]*\]'
    if ($rx.IsMatch($text)) { $text = $rx.Replace($text, [Text.RegularExpressions.MatchEvaluator]{ param($m) $new }, 1) }
    else {
        $end = $text.LastIndexOf('}')
        if ($end -lt 0) { throw 'Pimax Play settings file looks damaged; nothing was changed.' }
        $head = $text.Substring(0, $end).TrimEnd()
        $sep = if ($head.EndsWith('{')) { "`n`t" } else { ",`n`t" }
        $text = $head + $sep + $new + "`n" + $text.Substring($end)
    }
    $check = Get-PinnedIds $text
    if (($check -join '|') -ne ($ids -join '|')) { throw 'Order did not verify; nothing was changed.' }
    return $text
}

# ---------- Per-game settings (Pimax AppConfig) ----------
$AppConfigDir = Join-Path $PimaxDir 'AppConfig'
$Inv = [Globalization.CultureInfo]::InvariantCulture

# Mirrors the per-game settings in Pimax Play (keys, options and ranges from its settings screen)
$SettingDefs = @(
    @{ Key = 'piplay_display_quality_level'; Label = 'Image quality'; Kind = 'choice'; Default = 3
       Options = @(@(-1, 'Auto'), @(0, 'Low'), @(1, 'Medium'), @(2, 'High'), @(3, 'Custom')) },
    @{ Key = 'runtime_pixels_per_display_pixel_rate'; Label = 'Render resolution'; Kind = 'number'; Min = 0.1; Max = 2.0; Default = 1.0
       Tip = 'Used when Image quality is Custom. Low = 0.5, Medium = 0.75, High = 1.0' },
    @{ Key = 'runtime_overlay_render_scale'; Label = 'Overlay render factor'; Kind = 'number'; Min = 0.5; Max = 1.5; Default = 1.0 },
    @{ Key = 'runtime_quadviews_rendering_level'; Label = 'Quad View'; Kind = 'choice'; Default = 1
       Options = @(@(-1, 'Off'), @(0, 'Performance'), @(1, 'Balance'), @(2, 'Quality'), @(3, 'Ultimate'), @(5, 'Custom (fine-tune in Pimax Play)')) },
    @{ Key = 'runtime_fov_level'; Label = 'FOV crop'; Kind = 'choice'; Default = 0
       Options = @(@(0, 'Level 0 - widest (Normal/Wide)'), @(1, 'Level 1 - narrower'), @(2, 'Level 2 - narrower still'), @(3, 'Level 3 - narrowest (4-level headsets)'), @(9, 'Custom (fine-tune in Pimax Play)')) },
    @{ Key = 'runtime_foveated_rendering_level'; Label = 'Center rendering'; Kind = 'choice'; Default = 1
       Options = @(@(-1, 'Off'), @(0, 'Performance'), @(1, 'Balanced'), @(2, 'Quality')) },
    @{ Key = 'runtime_gpu_upscaling_algorithm'; Label = 'GPU upscaling'; Kind = 'choice'; Default = 0
       Options = @(@(0, 'None'), @(1, 'FSR'), @(2, 'NIS')) },
    @{ Key = 'runtime_gpu_upscaling_scaling'; Label = 'Upscaling ratio'; Kind = 'number'; Min = 1.0; Max = 2.0; Default = 1.3
       Tip = 'Used with FSR/NIS. Quality 1.3, Balanced 1.6, Performance 1.9' },
    @{ Key = 'runtime_gpu_upscaling_sharpness'; Label = 'Sharpness'; Kind = 'number'; Min = 0.0; Max = 1.0; Default = 0.6 },
    @{ Key = 'runtime_dbg_asw_enable'; Label = 'Smart Smoothing'; Kind = 'choice'; Default = 0
       Options = @(@(0, 'Off'), @(1, 'On')) },
    @{ Key = 'runtime_dbg_force_framerate_divide_by'; Label = 'Lock to half refresh rate'; Kind = 'choice'; Default = 1
       Options = @(@(1, 'Off'), @(2, 'On')) },
    @{ Key = 'piplay_color_tone_preset'; Label = 'Color tone'; Kind = 'choice'; Default = 0
       Options = @(@(0, 'Standard'), @(1, 'Cooler'), @(2, 'Cool'), @(3, 'Warm'), @(4, 'Warmer')) }
)
$QualityRates = @{ 0 = 0.5; 1 = 0.75; 2 = 1.0 }

function Get-SettingsPath([string]$id) { Join-Path $AppConfigDir ("{0}.json" -f $id) }

# Returns an ordered map of every key in the file (unknown keys kept as-is)
function Read-GameSettings([string]$id) {
    $map = [ordered]@{}
    $p = Get-SettingsPath $id
    if (-not (Test-Path -LiteralPath $p)) { return $map }
    $j = [IO.File]::ReadAllText($p).TrimStart([char]0xFEFF) | ConvertFrom-Json
    foreach ($prop in $j.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
    return $map
}

function Format-SettingValue($key, $value) {
    $def = $SettingDefs | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if ($value -is [pscustomobject]) { return ($value | ConvertTo-Json -Compress -Depth 5) }
    if ($value -is [string]) { return ($value | ConvertTo-Json) }
    if ($value -is [bool]) { return $(if ($value) { 'true' } else { 'false' }) }
    if ($def -and $def.Kind -eq 'number') {
        $s = ([double]$value).ToString('R', $Inv)
        if ($s -notmatch '[.eE]') { $s += '.0' }
        return $s
    }
    if ($value -is [double] -or $value -is [single] -or $value -is [decimal]) { return ([double]$value).ToString('R', $Inv) }
    return ([long]$value).ToString($Inv)
}

# Writes in Pimax's own layout; an empty game file is removed so the game falls back to global
function Write-GameSettings([string]$id, $map) {
    $p = Get-SettingsPath $id
    if (-not (Test-Path $AppConfigDir)) { New-Item -ItemType Directory -Path $AppConfigDir | Out-Null }
    if ($map.Count -eq 0 -and $id -ne 'global') { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }; return }
    $lines = foreach ($k in ($map.Keys | Sort-Object)) { '   "{0}" : {1}' -f $k, (Format-SettingValue $k $map[$k]) }
    $text = "{`n" + ($lines -join ",`n") + "`n}`n"
    $null = $text | ConvertFrom-Json   # validate before writing
    [IO.File]::WriteAllText($p, $text, $Utf8NoBom)
}

function Backup-SettingsOnce([string[]]$ids) {
    $dir = Join-Path $BackupDir 'settings'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    foreach ($id in $ids) {
        $src = Get-SettingsPath $id; $dst = Join-Path $dir ("{0}.json.orig" -f $id); $none = Join-Path $dir ("{0}.none" -f $id)
        if ((Test-Path $dst) -or (Test-Path $none)) { continue }
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src $dst } else { New-Item -ItemType File -Path $none | Out-Null }
    }
}

# Pimax's service keeps settings in memory, so change files only while it is stopped.
# -Full also stops the headset runtime (pi_server), which holds the headset profile and eye-tracking calibration.
function Invoke-WhilePimaxStopped([scriptblock]$action, [switch]$Full) {
    $client = Get-ClientPath
    Get-Process PimaxClient -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    $svcOk = $true
    try { Stop-Service $ServiceName -Force -ErrorAction Stop } catch { $svcOk = $false }
    Get-Process PiPlayService -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($Full) { Get-Process pi_server, pi_overlay, pi_vst, PimaxHome-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    $err = $null
    try { Write-PendingChanges; & $action } catch { $err = $_ }
    try { Start-Service $ServiceName -ErrorAction Stop } catch { $svcOk = $false }
    Start-Sleep -Seconds 3
    if (Test-Path $client) { Start-Process $client }
    $script:RuntimeBack = $true
    if ($Full) {
        $script:RuntimeBack = $false
        for ($i = 0; $i -lt 30 -and -not $script:RuntimeBack; $i++) { Start-Sleep -Seconds 1; $script:RuntimeBack = [bool](Get-Process pi_server -ErrorAction SilentlyContinue) }
    }
    if ($err) { throw $err }
    return $svcOk
}

# ---------- Headset settings (eye-tracking calibration, headset profile, play area) ----------
$HeadsetLocalDir   = Join-Path $env:LOCALAPPDATA 'Pimax\runtime'
$HeadsetProgramDir = Join-Path $env:ProgramData 'Pimax\runtime'
function Get-HeadsetFiles {
    $out = @()
    $pj = Join-Path $HeadsetLocalDir 'profile.json'
    if (Test-Path $pj) { $out += [pscustomobject]@{ Area = 'local'; Name = 'profile.json'; Path = $pj; Kind = 'Headset profile (IPD, custom FOV, Quad View fine-tuning, audio)' } }
    foreach ($f in Get-ChildItem $HeadsetLocalDir -Filter *.bin -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 5MB }) {
        $out += [pscustomobject]@{ Area = 'local'; Name = $f.Name; Path = $f.FullName; Kind = 'Eye-tracking calibration' }
    }
    foreach ($f in Get-ChildItem $HeadsetProgramDir -Filter *.vrchap -File -ErrorAction SilentlyContinue) {
        $out += [pscustomobject]@{ Area = 'programdata'; Name = $f.Name; Path = $f.FullName; Kind = 'Play area' }
    }
    $out
}
function Get-HeadsetTarget([string]$area, [string]$name) {
    if ($area -eq 'programdata') { Join-Path $HeadsetProgramDir $name } else { Join-Path $HeadsetLocalDir $name }
}

# ---------- Backups (snapshots of images, library order and game settings) ----------
function Get-Route($game) {
    if ($game.Route) { return [string]$game.Route }
    try { return [string](([IO.File]::ReadAllText($game.File).TrimStart([char]0xFEFF) | ConvertFrom-Json).route) } catch { return '' }
}

# ---------- Launching games ----------
# Uses the same launch path Pimax Play does: Steam links (steam://launch/<id>/VR) and shortcuts are opened as-is, an .exe is started in its own folder
function Get-LaunchTarget($game) {
    $route = (Get-Route $game).Trim('"', ' ')
    if (-not $route) { return $null }
    if ($route -match '^[a-zA-Z][a-zA-Z0-9+.-]+://') { return [pscustomobject]@{ Kind = 'link'; Path = $route } }
    if ($route -match '\.(lnk|url)$') { return [pscustomobject]@{ Kind = 'shortcut'; Path = $route } }
    return [pscustomobject]@{ Kind = 'exe'; Path = $route }
}

# The app runs as admin, so the game is opened through Explorer: it then runs as you, not as admin, just as it would from Pimax Play or Steam.
# Explorer would start an .exe in System32, so it goes through a shortcut that sets the game's own folder as the working folder.
function Start-Game($game) {
    $t = Get-LaunchTarget $game
    if (-not $t) { throw "Pimax Play has no launch path for this game." }
    if ($t.Kind -ne 'link' -and -not (Test-Path -LiteralPath $t.Path)) { throw "the game file wasn't found: $($t.Path)" }
    $open = $t.Path
    if ($t.Kind -eq 'exe') {
        $dir = Join-Path $DataDir 'launch'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $open = Join-Path $dir ((Get-GameId $game) + '.lnk')
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($open)
        $s.TargetPath = $t.Path; $s.WorkingDirectory = (Split-Path $t.Path -Parent); $s.Save()
    }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $open)
}

function Test-HasOrigBackup($game) {
    $n = [IO.Path]::GetFileName($game.File) + '.orig'
    return (Test-Path (Join-Path $BackupDir $n)) -or (Test-Path (Join-Path $LegacyBackupDir $n))
}

# Games whose tile image can be customised and kept: imported games (Pimax rebuilds Steam and Oculus entries itself)
function Get-CustomImages {
    foreach ($g in Get-PimaxGames) {
        $icon = [string]$g.Icon
        if (-not $icon) { continue }
        if ($g.Source -eq 'Imported') {
            [pscustomobject]@{ Id = (Get-GameId $g); Name = $g.Name; Route = (Get-Route $g); Icon = $icon }
        }
    }
}

function Get-StateFingerprint {
    $sb = New-Object Text.StringBuilder
    foreach ($i in (Get-CustomImages | Sort-Object Id)) {
        $h = if ($i.Icon -notmatch '^https?://' -and (Test-Path -LiteralPath $i.Icon)) { (Get-FileHash -LiteralPath $i.Icon -Algorithm MD5).Hash } else { $i.Icon }
        [void]$sb.Append("img|$($i.Id)|$h`n")
    }
    [void]$sb.Append('pins|' + ((Get-PinnedIds) -join ',') + "`n")
    foreach ($f in (Get-ChildItem $AppConfigDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name)) {
        [void]$sb.Append("cfg|$($f.Name)|$((Get-FileHash $f.FullName -Algorithm MD5).Hash)`n")
    }
    foreach ($hf in (Get-HeadsetFiles | Sort-Object Name)) {
        $txt = if ($hf.Name -eq 'profile.json') { [regex]::Replace([IO.File]::ReadAllText($hf.Path), '"GpuMeasure"\s*:\s*\{[^}]*\}', '') } else { (Get-FileHash $hf.Path -Algorithm MD5).Hash }
        [void]$sb.Append("hs|$($hf.Area)|$($hf.Name)|$($txt.GetHashCode())`n")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    return [BitConverter]::ToString((New-Object Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($bytes)).Replace('-', '')
}

function Get-Snapshots {
    $list = foreach ($d in Get-ChildItem $SnapshotDir -Directory -ErrorAction SilentlyContinue) {
        $meta = Join-Path $d.FullName 'snapshot.json'
        if (-not (Test-Path $meta)) { continue }
        try { $j = [IO.File]::ReadAllText($meta) | ConvertFrom-Json } catch { continue }
        $j | Add-Member -NotePropertyName Path -NotePropertyValue $d.FullName -Force
        $j
    }
    @($list | Sort-Object { [datetime]$_.created } -Descending)
}

# Saves a snapshot; with -IfChanged it is skipped when nothing differs from the newest one
function New-Snapshot([string]$reason, [switch]$IfChanged) {
    $fp = Get-StateFingerprint
    if ($IfChanged) { $last = Get-Snapshots | Select-Object -First 1; if ($last -and $last.fingerprint -eq $fp) { return $null } }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $dir = Join-Path $SnapshotDir $stamp; $n = 2
    while (Test-Path $dir) { $dir = Join-Path $SnapshotDir "$stamp-$n"; $n++ }
    New-Item -ItemType Directory -Path (Join-Path $dir 'images') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'settings') -Force | Out-Null
    $images = foreach ($i in Get-CustomImages) {
        $file = $null
        if ($i.Icon -notmatch '^https?://' -and (Test-Path -LiteralPath $i.Icon)) {
            $file = 'images/' + $i.Id + [IO.Path]::GetExtension($i.Icon).ToLower()
            Copy-Item -LiteralPath $i.Icon (Join-Path $dir $file.Replace('/', '\')) -Force
        }
        [pscustomobject]@{ id = $i.Id; name = $i.Name; route = $i.Route; file = $file; url = $(if ($i.Icon -match '^https?://') { $i.Icon } else { $null }) }
    }
    foreach ($f in Get-ChildItem $AppConfigDir -Filter *.json -ErrorAction SilentlyContinue) { Copy-Item $f.FullName (Join-Path $dir 'settings') }
    $headset = foreach ($hf in Get-HeadsetFiles) {
        $hd = Join-Path $dir ("headset\" + $hf.Area); New-Item -ItemType Directory -Force $hd | Out-Null
        Copy-Item -LiteralPath $hf.Path (Join-Path $hd $hf.Name) -Force
        [pscustomobject]@{ area = $hf.Area; name = $hf.Name; kind = $hf.Kind }
    }
    $games = foreach ($g in Get-PimaxGames) { [pscustomobject]@{ id = (Get-GameId $g); name = $g.Name; route = (Get-Route $g) } }
    $meta = [pscustomobject]@{
        created = (Get-Date).ToString('o'); reason = $reason; appVersion = $AppVersion; fingerprint = $fp
        pinned = @(Get-PinnedIds); images = @($images); games = @($games); headset = @($headset)
        settings = @(Get-ChildItem (Join-Path $dir 'settings') -Filter *.json | ForEach-Object BaseName)
    }
    [IO.File]::WriteAllText((Join-Path $dir 'snapshot.json'), ($meta | ConvertTo-Json -Depth 6), $Utf8NoBom)
    # keep the newest 20 automatic snapshots; ones you make yourself are kept
    Get-Snapshots | Where-Object { $_.reason -eq 'Automatic' } | Select-Object -Skip 20 | ForEach-Object { Remove-Item -LiteralPath $_.Path -Recurse -Force }
    return $dir
}

# Deletes backup folders - only ever ones inside the app's own snapshots folder
function Remove-Snapshots([string[]]$paths) {
    $root = [IO.Path]::GetFullPath($SnapshotDir).TrimEnd('\') + '\'
    $n = 0
    foreach ($p in $paths) {
        $full = [IO.Path]::GetFullPath($p)
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path (Join-Path $full 'snapshot.json'))) { throw "Not a backup folder: $p" }
        Remove-Item -LiteralPath $full -Recurse -Force
        $n++
    }
    return $n
}

function Save-AutoSnapshot { try { [void](New-Snapshot 'Automatic' -IfChanged) } catch { } }

# Maps a snapshot's game ID to the current one (re-imported games get new IDs, so fall back to the exe path)
function Resolve-SnapshotId($snap, [string]$oldId, $byId, $byRoute) {
    if ($oldId -eq 'global' -or $byId.ContainsKey($oldId)) { return $oldId }
    $old = $snap.games | Where-Object { $_.id -eq $oldId } | Select-Object -First 1
    $route = if ($old) { [string]$old.route } else { ($snap.images | Where-Object { $_.id -eq $oldId } | Select-Object -First 1).route }
    if ($route -and $byRoute.ContainsKey($route.ToLower())) { return $byRoute[$route.ToLower()] }
    return $null
}

function Get-CurrentIndex {
    $byId = @{}; $byRoute = @{}
    foreach ($g in Get-PimaxGames) {
        $id = Get-GameId $g; $byId[$id] = $g
        $r = Get-Route $g; if ($r) { $byRoute[$r.ToLower()] = $id }
    }
    [pscustomobject]@{ ById = $byId; ByRoute = $byRoute }
}

# What in the snapshot looks lost now (things Pimax resets, not normal edits)
function Compare-Snapshot($snap) {
    $idx = Get-CurrentIndex
    $lostImages = @(foreach ($i in $snap.images) {
        $cur = Resolve-SnapshotId $snap $i.id $idx.ById $idx.ByRoute
        if (-not $cur) { continue }
        $icon = [string]$idx.ById[$cur].Icon
        if (-not $icon -or ($i.file -and $icon -match '^https?://')) { $i.name }
    })
    $pinsNow = @(Get-PinnedIds)
    $lostPins = ($snap.pinned.Count -gt 0 -and $pinsNow.Count -eq 0)
    $lostSettings = @(foreach ($s in $snap.settings) {
        $cur = Resolve-SnapshotId $snap $s $idx.ById $idx.ByRoute
        if ($cur -and -not (Test-Path (Get-SettingsPath $cur))) { $s }
    })
    $lostHeadset = @(foreach ($h in @($snap.headset)) { if ($h -and -not (Test-Path (Get-HeadsetTarget $h.area $h.name))) { $h.kind } })
    [pscustomobject]@{ Images = $lostImages; Pins = $lostPins; Settings = $lostSettings; Headset = $lostHeadset
                       Any = ($lostImages.Count -gt 0 -or $lostPins -or $lostSettings.Count -gt 0 -or $lostHeadset.Count -gt 0) }
}

function Restore-Snapshot($snap, [bool]$images, [bool]$order, [bool]$settings, [bool]$headset = $false) {
    [void](New-Snapshot 'Before restore')
    $idx = Get-CurrentIndex
    $report = [ordered]@{ Images = 0; Order = 0; Settings = 0; Headset = 0; Skipped = @() }
    $svcOk = Invoke-WhilePimaxStopped -Full:$headset {
        if ($headset) {
            foreach ($h in @($snap.headset)) {
                if (-not $h) { continue }
                $src = Join-Path $snap.Path ("headset\" + $h.area + "\" + $h.name)
                if (-not (Test-Path -LiteralPath $src)) { continue }
                $dst = Get-HeadsetTarget $h.area $h.name
                New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
                Copy-Item -LiteralPath $src $dst -Force
                $report.Headset++
            }
        }
        if ($images) {
            foreach ($i in $snap.images) {
                $cur = Resolve-SnapshotId $snap $i.id $idx.ById $idx.ByRoute
                if (-not $cur) { $report.Skipped += $i.name; continue }
                $g = $idx.ById[$cur]
                $icon = $null
                if ($i.file) {
                    $src = Join-Path $snap.Path $i.file.Replace('/', '\')
                    if (Test-Path -LiteralPath $src) {
                        $icon = Join-Path $CoverDir ("{0}_restored_{1}{2}" -f $cur, (Get-Date -Format 'yyyyMMddHHmmss'), [IO.Path]::GetExtension($src))
                        Copy-Item -LiteralPath $src $icon -Force
                    }
                } elseif ($i.url) { $icon = $i.url }
                if (-not $icon) { $report.Skipped += $i.name; continue }
                $orig = Join-Path $BackupDir ([IO.Path]::GetFileName($g.File) + '.orig')
                if (-not (Test-HasOrigBackup $g)) { Copy-Item $g.File $orig }
                $j = [IO.File]::ReadAllText($g.File).TrimStart([char]0xFEFF) | ConvertFrom-Json
                if ($j.PSObject.Properties.Name -contains 'icon') { $j.icon = $icon } else { $j | Add-Member -NotePropertyName icon -NotePropertyValue $icon }
                [IO.File]::WriteAllText($g.File, ($j | ConvertTo-Json -Compress -Depth 10), $Utf8NoBom)
                $report.Images++
            }
        }
        if ($order -and (Test-Path $ClientConfig)) {
            $ids = @(foreach ($p in $snap.pinned) { $c = Resolve-SnapshotId $snap $p $idx.ById $idx.ByRoute; if ($c) { $c } else { $p } })
            $text = Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) $ids
            [IO.File]::WriteAllText($ClientConfig, $text, $Utf8NoBom)
            $report.Order = $ids.Count
        }
        if ($settings) {
            if (-not (Test-Path $AppConfigDir)) { New-Item -ItemType Directory -Path $AppConfigDir | Out-Null }
            foreach ($s in $snap.settings) {
                $cur = Resolve-SnapshotId $snap $s $idx.ById $idx.ByRoute
                if (-not $cur) { if ($snap.games | Where-Object { $_.id -eq $s }) { $report.Skipped += "settings for " + ($snap.games | Where-Object { $_.id -eq $s } | Select-Object -First 1).name }; continue }
                Copy-Item (Join-Path $snap.Path "settings\$s.json") (Get-SettingsPath $cur) -Force
                $report.Settings++
            }
        }
    }
    $report.ServiceOk = $svcOk
    $report.RuntimeBack = $script:RuntimeBack
    return [pscustomobject]$report
}

# ---------- Theme ----------
# Dark title bars on Windows 10/11 so the window frame matches the app
try { Add-Type -Namespace PGM -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);' -ErrorAction Stop } catch { }
function Set-DarkTitleBar($win) {
    try {
        $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
        $v = 1;          [void][PGM.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)   # dark mode title bar
        $v = 0x0014100E; [void][PGM.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$v, 4)   # caption colour (Windows 11)
        $v = 0x00382C26; [void][PGM.Dwm]::DwmSetWindowAttribute($h, 34, [ref]$v, 4)   # border colour (Windows 11)
    } catch { }
}

# Shared styles, icons (Ico*) and the app logo, inserted into every window where its XAML says __THEME__
$ThemeXaml = @'
    <SolidColorBrush x:Key="AccentBrush" Color="#5B8CFF"/>
    <LinearGradientBrush x:Key="LogoGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#22D3EE" Offset="0"/><GradientStop Color="#3B82F6" Offset="0.5"/><GradientStop Color="#8B5CF6" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="LineGrad" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#0022D3EE" Offset="0"/><GradientStop Color="#9022D3EE" Offset="0.3"/><GradientStop Color="#908B5CF6" Offset="0.7"/><GradientStop Color="#008B5CF6" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="LensGrad" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#1C2436" Offset="0"/><GradientStop Color="#07090D" Offset="1"/>
    </LinearGradientBrush>
    <Geometry x:Key="LogoVisor">M8 20 C8 17 10 16 13 16 H51 C54 16 56 17 56 20 L58 34 C58.5 39 56 43 51 43 H40 C37 43 35.5 41.5 34.5 39.5 L33.6 37.8 C33 36.6 31 36.6 30.4 37.8 L29.5 39.5 C28.5 41.5 27 43 24 43 H13 C8 43 5.5 39 6 34 Z</Geometry>
    <Geometry x:Key="LogoLenses">M12.5 24 H27 C29 24 30.2 25.5 29.8 27.5 L28.9 32 C28.5 34 27.2 35 25.2 35 H14.5 C12 35 10.6 33.4 11 31 L11.6 26 C11.8 24.8 12 24 12.5 24 Z M51.5 24 H37 C35 24 33.8 25.5 34.2 27.5 L35.1 32 C35.5 34 36.8 35 38.8 35 H49.5 C52 35 53.4 33.4 53 31 L52.4 26 C52.2 24.8 52 24 51.5 24 Z</Geometry>
    <DrawingImage x:Key="LogoImage">
      <DrawingImage.Drawing>
        <DrawingGroup>
          <GeometryDrawing Brush="{StaticResource LogoGrad}" Geometry="{StaticResource LogoVisor}"/>
          <GeometryDrawing Brush="{StaticResource LensGrad}" Geometry="{StaticResource LogoLenses}"/>
          <GeometryDrawing Geometry="M15 19 H49"><GeometryDrawing.Pen><Pen Brush="#70FFFFFF" Thickness="1.2" StartLineCap="Round" EndLineCap="Round"/></GeometryDrawing.Pen></GeometryDrawing>
          <GeometryDrawing Geometry="M15.5 27.5 H20.5 M38.5 27.5 H43.5"><GeometryDrawing.Pen><Pen Brush="#A0FFFFFF" Thickness="1.3" StartLineCap="Round" EndLineCap="Round"/></GeometryDrawing.Pen></GeometryDrawing>
        </DrawingGroup>
      </DrawingImage.Drawing>
    </DrawingImage>
    <Geometry x:Key="IcoSearch">M10.5 4 a6.5 6.5 0 1 1 0 13 a6.5 6.5 0 1 1 0 -13 Z M15.5 15.5 L20.5 20.5</Geometry>
    <Geometry x:Key="IcoFolder">M3 7 C3 6.4 3.4 6 4 6 H10 L12 8.5 H20 C20.6 8.5 21 8.9 21 9.5 V18 C21 18.6 20.6 19 20 19 H4 C3.4 19 3 18.6 3 18 Z</Geometry>
    <Geometry x:Key="IcoEye">M2 12 C5 6.5 19 6.5 22 12 C19 17.5 5 17.5 2 12 Z M12 9.5 a2.5 2.5 0 1 1 0 5 a2.5 2.5 0 1 1 0 -5 Z</Geometry>
    <Geometry x:Key="IcoCheck">M5 12.5 L10 17.5 L19.5 7</Geometry>
    <Geometry x:Key="IcoUndo">M8.5 5 L4 9.5 L8.5 14 M4 9.5 H14.5 C18 9.5 20.5 12 20.5 15 C20.5 18 18 20 14.5 20 H10</Geometry>
    <Geometry x:Key="IcoRefresh">M20 12 A8 8 0 1 1 17.66 6.34 M20 4 V9 H15</Geometry>
    <Geometry x:Key="IcoPower">M12 3 V11 M7 6.2 A8 8 0 1 0 17 6.2</Geometry>
    <Geometry x:Key="IcoKey">M8 10 a4.5 4.5 0 1 1 0 9 a4.5 4.5 0 1 1 0 -9 Z M11.2 11.3 L20 2.5 M16.5 6 L19.5 9 M18.5 4 L21 6.5</Geometry>
    <Geometry x:Key="IcoList">M9 6 H20 M9 12 H20 M9 18 H20 M4.5 6 H5 M4.5 12 H5 M4.5 18 H5</Geometry>
    <Geometry x:Key="IcoSliders">M4 7 H7 M11 7 H20 M9 5 a2 2 0 1 1 0 4 a2 2 0 1 1 0 -4 Z M4 17 H13 M17 17 H20 M15 15 a2 2 0 1 1 0 4 a2 2 0 1 1 0 -4 Z</Geometry>
    <Geometry x:Key="IcoArchive">M3.5 4.5 H20.5 V8.5 H3.5 Z M5 8.5 V19 C5 19.6 5.4 20 6 20 H18 C18.6 20 19 19.6 19 19 V8.5 M10 12.5 H14</Geometry>
    <Geometry x:Key="IcoDownload">M12 4 V15 M7 10.5 L12 15.5 L17 10.5 M5 20 H19</Geometry>
    <Geometry x:Key="IcoSave">M5 4 H16 L20 8 V19 C20 19.6 19.6 20 19 20 H5 C4.4 20 4 19.6 4 19 V5 C4 4.4 4.4 4 5 4 Z M8 4 V8.5 H15 V4 M7.5 20 V14 H16.5 V20</Geometry>
    <Geometry x:Key="IcoTrash">M4 7 H20 M9.5 7 V4.5 H14.5 V7 M6 7 L7 19.5 C7 20 7.4 20.5 8 20.5 H16 C16.6 20.5 17 20 17 19.5 L18 7 M10 11 V17 M14 11 V17</Geometry>
    <Geometry x:Key="IcoCopy">M9 9 H20 V20 H9 Z M15 9 V4 H4 V15 H9</Geometry>
    <Geometry x:Key="IcoPin">M9 3.5 H15 M10 3.5 V9 L6.5 13.5 H17.5 L14 9 V3.5 M12 13.5 V21</Geometry>
    <Geometry x:Key="IcoSort">M4 6 H13 M4 12 H10 M4 18 H7 M17.5 5 V19 M14.5 16 L17.5 19 L20.5 16</Geometry>
    <Geometry x:Key="IcoUp">M12 19 V5 M6 11 L12 5 L18 11</Geometry>
    <Geometry x:Key="IcoDown">M12 5 V19 M6 13 L12 19 L18 13</Geometry>
    <Geometry x:Key="IcoTop">M5 4 H19 M12 20 V9 M7 14 L12 9 L17 14</Geometry>
    <Geometry x:Key="IcoBottom">M5 20 H19 M12 4 V15 M7 10 L12 15 L17 10</Geometry>
    <Geometry x:Key="IcoClose">M6 6 L18 18 M18 6 L6 18</Geometry>
    <Geometry x:Key="IcoImage">M4 5 H20 C20.6 5 21 5.4 21 6 V18 C21 18.6 20.6 19 20 19 H4 C3.4 19 3 18.6 3 18 V6 C3 5.4 3.4 5 4 5 Z M3 15.5 L8.5 10.5 L13.5 15 L16.5 12.5 L21 16.5 M15.5 7.5 a1.5 1.5 0 1 1 0 3 a1.5 1.5 0 1 1 0 -3 Z</Geometry>
    <Geometry x:Key="IcoArrowRight">M5 12 H19 M13 6 L19 12 L13 18</Geometry>
    <Geometry x:Key="IcoArrowLeft">M19 12 H5 M11 6 L5 12 L11 18</Geometry>
    <Geometry x:Key="IcoPlus">M12 5 V19 M5 12 H19</Geometry>
    <Geometry x:Key="IcoPlay">M7.5 4.5 L19 12 L7.5 19.5 Z</Geometry>
    <Geometry x:Key="IcoGauge">M3.5 17.5 A9 9 0 1 1 20.5 17.5 M12 14.5 L16.5 9 M12 13 a1.5 1.5 0 1 1 0 3 a1.5 1.5 0 1 1 0 -3 Z</Geometry>
    <Geometry x:Key="IcoEdit">M4 20 H8.5 L19.5 9 C20.3 8.2 20.3 6.8 19.5 6 L18 4.5 C17.2 3.7 15.8 3.7 15 4.5 L4 15.5 Z M13.5 6 L18 10.5</Geometry>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1B1F28"/><Setter Property="Foreground" Value="#E8EBF2"/>
      <Setter Property="BorderBrush" Value="#2E3542"/><Setter Property="Padding" Value="9,6"/>
    </Style>
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Background" Value="#1F2430"/><Setter Property="Foreground" Value="#E8EBF2"/>
      <Setter Property="BorderBrush" Value="#2E3542"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="13,7"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" CornerRadius="7" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"/>
              <Border x:Name="Hl" CornerRadius="7" Background="#FFFFFF" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hl" Property="Opacity" Value="0.07"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Hl" Property="Opacity" Value="0.14"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#5B8CFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button" BasedOn="{StaticResource BtnBase}"/>
    <Style x:Key="IconBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" CornerRadius="7" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"/>
              <Border x:Name="Hl" CornerRadius="7" Background="#FFFFFF" Opacity="0"/>
              <StackPanel Orientation="Horizontal" Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}">
                <Viewbox Width="14" Height="14" VerticalAlignment="Center">
                  <Canvas Width="24" Height="24">
                    <Path Data="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" Stroke="{Binding Foreground, RelativeSource={RelativeSource TemplatedParent}}"
                          StrokeThickness="2.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                  </Canvas>
                </Viewbox>
                <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
              </StackPanel>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hl" Property="Opacity" Value="0.07"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Hl" Property="Opacity" Value="0.14"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#5B8CFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#161A21"/><Setter Property="Foreground" Value="#E8EBF2"/>
      <Setter Property="BorderBrush" Value="#2A303C"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/><Setter Property="CaretBrush" Value="#E8EBF2"/>
      <Setter Property="SelectionBrush" Value="#5B8CFF"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" CornerRadius="7" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                            Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3A4252"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#5B8CFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8EBF2"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" BorderThickness="1.6" BorderBrush="#7A849A" Background="#1E2430" VerticalAlignment="Center">
                <Path x:Name="Mark" Data="M3 7.5 L6 10.5 L11 4.5" Stroke="#FFFFFF" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter x:Name="Cp" Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#5B8CFF"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#2F6BFF"/><Setter TargetName="Box" Property="BorderBrush" Value="#5B8CFF"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="HasContent" Value="False"><Setter TargetName="Cp" Property="Margin" Value="0"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#E8EBF2"/><Setter Property="Background" Value="#161A21"/>
      <Setter Property="BorderBrush" Value="#2A303C"/><Setter Property="MinHeight" Value="30"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" CornerRadius="7" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0" Data="M0 0 L4.5 4.5 L9 0" Stroke="#8B93A5"
                            StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3A4252"/></Trigger>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#5B8CFF"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="10,5,30,5" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="#1B1F28" BorderBrush="#2E3542" BorderThickness="1" CornerRadius="8" Padding="4" Margin="0,4,0,0"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer SnapsToDevicePixels="True"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#E8EBF2"/><Setter Property="Padding" Value="10,6"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" CornerRadius="5" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1D2740"/></Trigger>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#252C3B"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="#161A21"/><Setter Property="Foreground" Value="#E8EBF2"/>
      <Setter Property="BorderBrush" Value="#262C38"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="4"/><Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBox">
            <Border CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer Focusable="False" Padding="{TemplateBinding Padding}"><ItemsPresenter/></ScrollViewer>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="8,6"/><Setter Property="Margin" Value="0,1"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Grid>
              <Border x:Name="Bd" CornerRadius="6" Background="{TemplateBinding Background}"/>
              <Border x:Name="Bar" Width="3" CornerRadius="1.5" HorizontalAlignment="Left" Margin="0,5" Background="{StaticResource LogoGrad}" Visibility="Collapsed"/>
              <Border BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1C212B"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1D2740"/><Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="{TemplateBinding Background}">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
                    <Border x:Name="T" CornerRadius="3" Background="#343B4A" Margin="2"/>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="#4A5367"/></Trigger>
                      <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="#5B8CFF"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate></Thumb.Template></Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/><Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="{TemplateBinding Background}">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                    <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
                        <Border x:Name="T" CornerRadius="3" Background="#343B4A" Margin="2"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="#4A5367"/></Trigger>
                          <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="#5B8CFF"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate></Thumb.Template></Thumb>
                    </Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
'@

# ---------- Window ----------
[xml]$xaml = (@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pimax Game Manager" Width="1100" Height="700" MinWidth="960" MinHeight="580"
        Background="#0E1014" Foreground="#E8EBF2" FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterScreen">
  <Window.Resources>__THEME__</Window.Resources>
  <Grid Margin="20,16,20,14">
    <Grid.ColumnDefinitions><ColumnDefinition Width="350"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <Grid Grid.Row="0" Grid.ColumnSpan="3" Margin="0,0,0,14">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoKey}" x:Name="KeyBtn" Content="SteamGridDB key"
                  ToolTip="Add a free SteamGridDB API key for many more images"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoPower}" x:Name="RestartBtn" Content="Restart Pimax Play" Margin="8,0,0,0"
                  ToolTip="Restart Pimax Play (applies any waiting changes)"/>
        </StackPanel>
        <Image Source="{StaticResource LogoImage}" Height="34" Margin="0,0,14,0" VerticalAlignment="Center"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock FontSize="21" FontWeight="SemiBold"><Run Text="Pimax"/><Run Text=" Game Manager" Foreground="{StaticResource LogoGrad}"/></TextBlock>
          <TextBlock Text="Play &amp; add games  &#183;  library images  &#183;  library order  &#183;  game settings  &#183;  performance  &#183;  backups" Foreground="#8B93A5" FontSize="12" Margin="1,1,0,0"/>
        </StackPanel>
      </DockPanel>
      <Border Grid.Row="1" Height="1" Margin="0,14,0,0" Background="{StaticResource LineGrad}"/>
    </Grid>

    <StackPanel Grid.Row="1" Grid.ColumnSpan="3">
      <Border x:Name="UpdateBar" Visibility="Collapsed" Background="#0F1D3A" BorderBrush="#2F4F8F"
              BorderThickness="1" CornerRadius="9" Padding="14,9" Margin="0,0,0,12">
        <DockPanel>
          <Button x:Name="UpdateClose" DockPanel.Dock="Right" Content="Later" Margin="8,0,0,0" Padding="12,5"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoDownload}" x:Name="UpdateBtn" DockPanel.Dock="Right" Content="Download"
                  Padding="12,5" Background="#2F6BFF" BorderBrush="#5B8CFF" FontWeight="SemiBold"/>
          <TextBlock x:Name="UpdateText" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
      </Border>
      <Border x:Name="ResetBar" Visibility="Collapsed" Background="#2D1E0E" BorderBrush="#7C4A1E"
              BorderThickness="1" CornerRadius="9" Padding="14,9" Margin="0,0,0,12">
        <DockPanel>
          <Button x:Name="ResetDismiss" DockPanel.Dock="Right" Content="Dismiss" Margin="8,0,0,0" Padding="12,5"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoUndo}" x:Name="ResetRestore" DockPanel.Dock="Right" Content="Restore..."
                  Padding="12,5" Background="#EA580C" BorderBrush="#FB923C" FontWeight="SemiBold"/>
          <TextBlock x:Name="ResetText" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
      </Border>
      <Border x:Name="PendingBar" Visibility="Collapsed" Background="#2A2410" BorderBrush="#8A6D1F"
              BorderThickness="1" CornerRadius="9" Padding="14,9" Margin="0,0,0,12">
        <DockPanel>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoUndo}" x:Name="PendingDiscard" DockPanel.Dock="Right" Content="Discard" Margin="8,0,0,0" Padding="12,5"
                  ToolTip="Throw away the waiting changes"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoCheck}" x:Name="PendingApply" DockPanel.Dock="Right" Content="Apply &amp; restart Pimax Play"
                  Padding="12,5" Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold" ToolTip="Write all waiting changes and restart Pimax Play once"/>
          <TextBlock x:Name="PendingText" VerticalAlignment="Center" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="40"/>
        </DockPanel>
      </Border>
    </StackPanel>

    <Border Grid.Row="2" Grid.Column="0" Background="#14171E" BorderBrush="#222733" BorderThickness="1" CornerRadius="12" Padding="12">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="4,2,4,10">
          <TextBlock x:Name="LibCount" DockPanel.Dock="Right" Foreground="#8B93A5" VerticalAlignment="Center"/>
          <TextBlock Text="Your Pimax library" FontSize="15" FontWeight="SemiBold"/>
        </DockPanel>
        <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="8"/><RowDefinition/><RowDefinition Height="8"/><RowDefinition/><RowDefinition Height="8"/><RowDefinition/></Grid.RowDefinitions>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoPlus}" x:Name="AddBtn" Grid.Row="0" Grid.Column="0" Content="Add games..."
                  Padding="8,8" Background="#0F2A33" BorderBrush="#1E6A7A" ToolTip="Add games to Pimax Play: pick .exe files or shortcuts, or scan a folder"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoEdit}" x:Name="EditBtn" Grid.Row="0" Grid.Column="2" Content="Edit / remove..."
                  Padding="8,8" ToolTip="Rename the selected imported game, change its .exe, or remove it from Pimax Play"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoList}" x:Name="OrderBtn" Grid.Row="2" Grid.Column="0" Content="Library order..."
                  Padding="8,8" Background="#1B2A4A" BorderBrush="#2F4F8F"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoSliders}" x:Name="SettingsBtn" Grid.Row="2" Grid.Column="2" Content="Game settings..."
                  Padding="8,8" Background="#1B2A4A" BorderBrush="#2F4F8F"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoRefresh}" x:Name="RefreshBtn" Grid.Row="4" Grid.Column="0" Content="Refresh list" Padding="8,8"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoArchive}" x:Name="BackupBtn" Grid.Row="4" Grid.Column="2" Content="Backup &amp; restore..." Padding="8,8"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoGauge}" x:Name="PerfBtn" Grid.Row="6" Grid.Column="0" Grid.ColumnSpan="3" Content="Performance..."
                  Padding="8,8" Background="#2A1F3D" BorderBrush="#6D4BB3" ToolTip="Lock a game's own graphics settings (truck, racing and flight sims), run it on the performance cores, keep its window on screen"/>
        </Grid>
        <ListBox x:Name="GameList" Background="Transparent" BorderThickness="0" Padding="0"/>
      </DockPanel>
    </Border>

    <Border Grid.Row="2" Grid.Column="2" Background="#14171E" BorderBrush="#222733" BorderThickness="1" CornerRadius="12" Padding="18,16">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top">
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoPlay}" x:Name="PlayBtn" DockPanel.Dock="Right" Content="Play" IsEnabled="False"
                  Margin="12,0,0,0" Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold" VerticalAlignment="Center"
                  ToolTip="Start this game, the same way Pimax Play does (or double-click it in the list)"/>
          <TextBlock x:Name="GameTitle" Text="Pick a game on the left" FontSize="20" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBlock x:Name="GameInfo" DockPanel.Dock="Top" Foreground="#8B93A5" Margin="0,3,0,12" TextWrapping="Wrap"/>
        <StackPanel DockPanel.Dock="Bottom">
          <TextBlock Text="New image: click Find image, paste a link, or browse for a file" Foreground="#B4BCCC" Margin="0,14,0,6"/>
          <DockPanel>
            <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoSearch}" x:Name="FindBtn" DockPanel.Dock="Right" Content="Find image"
                    Margin="8,0,0,0" Background="#2F6BFF" BorderBrush="#5B8CFF" FontWeight="SemiBold"/>
            <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoFolder}" x:Name="BrowseBtn" DockPanel.Dock="Right" Content="Browse..." Margin="8,0,0,0"/>
            <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoEye}" x:Name="PreviewBtn" DockPanel.Dock="Right" Content="Preview" Margin="8,0,0,0"/>
            <TextBox x:Name="SourceBox"/>
          </DockPanel>
          <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
            <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoCheck}" x:Name="ApplyBtn" Content="Use image"
                    Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold"/>
            <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoUndo}" x:Name="RestoreBtn" Content="Restore original" Margin="8,0,0,0"/>
          </StackPanel>
        </StackPanel>
        <Border Background="#0A0C10" CornerRadius="10" BorderBrush="#222733" BorderThickness="1">
          <Grid>
            <StackPanel x:Name="NoImage" HorizontalAlignment="Center" VerticalAlignment="Center">
              <Image Source="{StaticResource LogoImage}" Height="44" Opacity="0.18"/>
              <TextBlock Text="No custom image" Foreground="#4B5263" HorizontalAlignment="Center" Margin="0,10,0,0"/>
            </StackPanel>
            <Image x:Name="PreviewImg" Stretch="Uniform" Margin="10"/>
          </Grid>
        </Border>
      </DockPanel>
    </Border>

    <DockPanel Grid.Row="3" Grid.ColumnSpan="3" Margin="2,12,2,0">
      <TextBlock x:Name="VersionLabel" DockPanel.Dock="Right" Margin="18,0,0,0" Foreground="#7A8397" Cursor="Hand"
                 VerticalAlignment="Bottom" ToolTip="Click to check for updates"/>
      <TextBlock x:Name="ReportLink" DockPanel.Dock="Right" Margin="18,0,0,0" Foreground="#5B8CFF" Cursor="Hand"
                 VerticalAlignment="Bottom" Text="Report a problem" ToolTip="Open a bug report on GitHub (needs a free GitHub account)"/>
      <TextBlock x:Name="TutorialLink" DockPanel.Dock="Right" Margin="18,0,0,0" Foreground="#5B8CFF" Cursor="Hand"
                 VerticalAlignment="Bottom" Text="Tutorial" ToolTip="Show the quick tour again"/>
      <TextBlock x:Name="Status" Foreground="#4ADE80" TextWrapping="Wrap"
                 Text="Wide banner images (about 460x215 or 920x430) fit Pimax tiles best."/>
    </DockPanel>
  </Grid>
</Window>
'@).Replace('__THEME__', $ThemeXaml)
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'GameList','PlayBtn','PerfBtn','AddBtn','EditBtn','RefreshBtn','OrderBtn','SettingsBtn','GameTitle','GameInfo','SourceBox','BrowseBtn','PreviewBtn','FindBtn','KeyBtn','ApplyBtn','RestoreBtn','RestartBtn','PreviewImg','NoImage','Status','UpdateBar','UpdateText','UpdateBtn','UpdateClose','VersionLabel','ReportLink','TutorialLink','LibCount','BackupBtn','ResetBar','ResetText','ResetRestore','ResetDismiss','PendingBar','PendingText','PendingApply','PendingDiscard') { $ui[$n] = $window.FindName($n) }
$window.Title = "Pimax Game Manager $AppVersion"
$window.Add_SourceInitialized({ Set-DarkTitleBar $this })

# Window icon: the exe's own icon, or PimaxGameManager.ico next to the script
$script:AppIcon = $null
try {
    Add-Type -AssemblyName System.Drawing
    $exePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $ico = $null
    if ([IO.Path]::GetFileNameWithoutExtension($exePath) -ieq 'PimaxGameManager') { $ico = [Drawing.Icon]::ExtractAssociatedIcon($exePath) }
    elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'PimaxGameManager.ico'))) { $ico = New-Object Drawing.Icon (Join-Path $PSScriptRoot 'PimaxGameManager.ico') }
    if ($ico) {
        $script:AppIcon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $window.Icon = $script:AppIcon
    }
} catch { }

# ---------- Behaviour ----------
function Set-Status([string]$msg, [bool]$isError = $false) {
    $ui.Status.Foreground = if ($isError) { '#F87171' } else { '#4ADE80' }
    $ui.Status.Text = $msg
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
}

function Show-Preview([string]$source) {
    $ui.PreviewImg.Source = $null; $ui.NoImage.Visibility = 'Visible'
    if (-not $source) { return }
    if ($source -notmatch '^https?://' -and -not (Test-Path -LiteralPath $source)) { return }
    $ui.PreviewImg.Source = Load-Bitmap $source
    $ui.NoImage.Visibility = 'Collapsed'
}

function Selected-Game { if ($ui.GameList.SelectedItem) { $ui.GameList.SelectedItem.Tag } }

function Fill-List {
    $keep = (Selected-Game).File
    if ($script:SelectAfterFill) { $keep = $script:SelectAfterFill; $script:SelectAfterFill = $null }
    $ui.GameList.Items.Clear()
    $newBadge = { param($text, $fg, $bg) $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.FontSize = 11; $t.Foreground = $fg
                  $b = New-Object Windows.Controls.Border; $b.Child = $t; $b.Background = $bg; $b.CornerRadius = '4'; $b.Padding = '6,1,6,2'; $b.Margin = '6,0,0,0'; $b.VerticalAlignment = 'Center'
                  [Windows.Controls.DockPanel]::SetDock($b, 'Right'); $b }
    foreach ($g in Get-PimaxGames -WithPending) {
        $item = New-Object Windows.Controls.ListBoxItem
        $name = New-Object Windows.Controls.TextBlock
        $name.Text = $g.Name; $name.TextTrimming = 'CharacterEllipsis'; $name.VerticalAlignment = 'Center'
        $pal = switch ($g.Source) { 'Imported' { '#22D3EE', '#0F2A33' } 'SteamVR' { '#93B4FF', '#172340' } 'Oculus' { '#C4B5FD', '#231B3B' } default { '#9AA3B5', '#1F2430' } }
        $row = New-Object Windows.Controls.DockPanel
        [void]$row.Children.Add((& $newBadge $g.Source $pal[0] $pal[1]))
        if ($g.Pending) {
            $pb = & $newBadge $(if ($g.Pending -eq 'new') { 'New' } else { 'Changed' }) '#FBBF24' '#3A2E0E'
            $pb.ToolTip = 'Waiting to be applied - click Apply & restart Pimax Play at the top'
            [void]$row.Children.Add($pb)
        }
        [void]$row.Children.Add($name)
        $item.Content = $row
        $item.Tag = $g; $item.Padding = '10,7'
        [void]$ui.GameList.Items.Add($item)
        if ($g.File -eq $keep) { $ui.GameList.SelectedItem = $item }
    }
    $ui.LibCount.Text = "$($ui.GameList.Items.Count) games"
    Update-PendingBar
}

function Update-PendingBar {
    $n = $script:Pending.Count
    if (-not $n) { $ui.PendingBar.Visibility = 'Collapsed'; return }
    $labels = @($script:Pending | ForEach-Object { Get-PendingLabel $_ })
    $ui.PendingText.Text = "$n change$(if ($n -ne 1) { 's' }) waiting to be applied:  " + ($labels -join ',  ')
    $ui.PendingText.ToolTip = "Waiting to be applied (Pimax Play restarts once):`n" + (($labels | ForEach-Object { "  - $_" }) -join "`n")
    $ui.PendingBar.Visibility = 'Visible'
}

# Writes all waiting changes and restarts Pimax Play once. Returns $true when everything was applied.
function Invoke-ApplyPending {
    $n = $script:Pending.Count
    Set-Status $(if ($n) { "Applying $n change$(if ($n -ne 1) { 's' }) - restarting Pimax Play..." } else { 'Restarting Pimax Play...' })
    $ui.PendingApply.IsEnabled = $false; $ui.RestartBtn.IsEnabled = $false
    try { $ok = Invoke-WhilePimaxStopped { } }
    catch { $ok = $false; $script:ApplyErrors += $_.Exception.Message }
    finally { $ui.PendingApply.IsEnabled = $true; $ui.RestartBtn.IsEnabled = $true }
    Fill-List
    Save-AutoSnapshot
    $msg = if ($n) { "Applied $script:LastApplied change$(if ($script:LastApplied -ne 1) { 's' }) and restarted Pimax Play." } else { 'Pimax Play restarted.' }
    $bad = $false
    if ($script:ApplyErrors.Count) { $msg += "  Couldn't apply: $($script:ApplyErrors -join '; ')"; $bad = $true }
    if (-not $ok) { $msg += '  (Couldn''t restart the Pimax service - restart your PC if the changes don''t show.)'; $bad = $true }
    Set-Status $msg $bad
    return (-not $script:Pending.Count)
}

$ui.PendingApply.Add_Click({ [void](Invoke-ApplyPending) })
$ui.PendingDiscard.Add_Click({
    $n = $script:Pending.Count
    $a = [Windows.MessageBox]::Show("Throw away $n waiting change$(if ($n -ne 1) { 's' })? Nothing has been written to Pimax Play yet.", 'Discard changes', 'YesNo', 'Question')
    if ($a -ne 'Yes') { return }
    $script:Pending.Clear()
    Fill-List
    Show-Preview (Selected-Game).Icon
    Set-Status "Discarded $n change$(if ($n -ne 1) { 's' })."
})

# Closing with waiting changes: apply them, throw them away, or stay
$window.Add_Closing({
    if ($Test -or -not $script:Pending.Count) { return }
    $n = $script:Pending.Count
    $list = (@($script:Pending | Select-Object -First 12 | ForEach-Object { '  - ' + (Get-PendingLabel $_) }) -join "`n") + $(if ($n -gt 12) { "`n  ...and $($n - 12) more" })
    $a = [Windows.MessageBox]::Show("You have $n change$(if ($n -ne 1) { 's' }) that haven't been applied to Pimax Play yet:`n`n$list`n`nApply them now? Pimax Play will restart.`n`nYes: apply and close.   No: throw them away and close.   Cancel: keep working.", 'Apply changes?', 'YesNoCancel', 'Question')
    if ($a -eq 'Cancel') { $_.Cancel = $true; return }
    if ($a -eq 'No') { $script:Pending.Clear(); return }
    if (-not (Invoke-ApplyPending)) {
        $_.Cancel = $true
        [Windows.MessageBox]::Show("Some changes couldn't be applied, so the app is staying open. Details are at the bottom of the window.", 'Apply changes', 'OK', 'Warning') | Out-Null
    }
})

$ui.GameList.Add_SelectionChanged({
    $g = Selected-Game
    if (-not $g) { return }
    $ui.GameTitle.Text = $g.Name
    $canChange = ($g.Source -eq 'Imported')
    $info = "Source: $($g.Source)"
    if ($canChange) { $r = Get-Route $g; if ($r) { $info += "   -  $r" } }
    if (-not $canChange) { $info += "   -  Pimax takes this game's image from $(if ($g.Source -eq 'Oculus') { 'Oculus' } else { 'Steam' }) every time it starts, so it can't be changed here. To use your own image, add the game's .exe with Add games... and give that entry an image." }
    $ui.GameInfo.Text = $info
    $ui.SourceBox.Text = ''
    foreach ($b in $ui.ApplyBtn, $ui.FindBtn, $ui.BrowseBtn, $ui.PreviewBtn, $ui.SourceBox, $ui.EditBtn) { $b.IsEnabled = $canChange }
    $ui.RestoreBtn.IsEnabled = $canChange
    $ui.PlayBtn.IsEnabled = [bool](Get-LaunchTarget $g)
    try { Show-Preview $g.Icon; Set-Status $(if ($canChange) { 'Showing the current image.' } else { 'Images can only be changed for imported games.' }) } catch { Set-Status 'Current image could not be loaded.' $true }
})

$ui.BrowseBtn.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Images|*.jpg;*.jpeg;*.png;*.webp;*.bmp;*.gif|All files|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $ui.SourceBox.Text = $dlg.FileName
        try { Show-Preview $dlg.FileName; Set-Status 'Preview of the new image. Click "Use image" to use it.' } catch { Set-Status "Couldn't read that image." $true }
    }
})

$ui.PreviewBtn.Add_Click({
    $src = $ui.SourceBox.Text.Trim('"', ' ')
    if (-not $src) { Set-Status 'Paste a link or choose a file first.' $true; return }
    Set-Status 'Loading preview...'
    try { Show-Preview $src; Set-Status 'Preview of the new image. Click "Use image" to use it.' } catch { Set-Status "Couldn't load that image: $($_.Exception.Message)" $true }
})

$WaitingHint = 'Keep going, then click Apply & restart Pimax Play at the top when you''re done.'

$ui.ApplyBtn.Add_Click({
    $g = Selected-Game
    if (-not $g) { Set-Status 'Pick a game on the left first.' $true; return }
    $src = $ui.SourceBox.Text.Trim('"', ' ')
    if (-not $src) { Set-Status 'Paste a link or choose a file first.' $true; return }
    if ($src -notmatch '^https?://' -and -not (Test-Path -LiteralPath $src)) { Set-Status "File not found: $src" $true; return }
    try {
        Set-Status 'Saving image...'
        $dest = Save-Cover $g $src
        Fill-List
        Show-Preview $dest
        $ui.SourceBox.Text = ''
        Set-Status "New image for $($g.Name) is waiting to be applied. $WaitingHint"
    } catch { Set-Status "Couldn't use the image: $($_.Exception.Message)" $true }
})

$ui.RestoreBtn.Add_Click({
    $g = Selected-Game
    if (-not $g) { Set-Status 'Pick a game on the left first.' $true; return }
    $r = [Windows.MessageBox]::Show("Put $($g.Name) back to its original image?", 'Restore original', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try {
        Restore-Cover $g
        Fill-List
        Show-Preview (Selected-Game).Icon
        Set-Status $(if ($script:Pending.Count) { "Original image for $($g.Name) is waiting to be applied. $WaitingHint" } else { "$($g.Name) is back to its original image." })
    } catch { Set-Status $_.Exception.Message $true }
})

function Show-Finder($game) {
    [xml]$fx = (@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Find image" Width="1010" Height="660" Background="#0E1014" Foreground="#E8EBF2"
        FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterOwner">
  <Window.Resources>__THEME__</Window.Resources>
  <DockPanel Margin="16">
    <DockPanel DockPanel.Dock="Top">
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoSearch}" x:Name="SearchBtn" DockPanel.Dock="Right" Content="Search by name" Margin="8,0,0,0"/>
      <TextBox x:Name="Term"/>
    </DockPanel>
    <TextBlock x:Name="Note" DockPanel.Dock="Top" Foreground="#8B93A5" Margin="0,8,0,8" TextWrapping="Wrap"/>
    <TextBlock DockPanel.Dock="Bottom" Text="Click an image to use it." Foreground="#8B93A5" Margin="0,8,0,0"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><WrapPanel x:Name="Results"/></ScrollViewer>
  </DockPanel>
</Window>
'@).Replace('__THEME__', $ThemeXaml)
    $fw = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $fx))
    $fw.Owner = $window
    if ($script:AppIcon) { $fw.Icon = $script:AppIcon }
    $fw.Add_SourceInitialized({ Set-DarkTitleBar $this })
    $script:finderPick = $null
    $termBox = $fw.FindName('Term'); $noteBlock = $fw.FindName('Note'); $results = $fw.FindName('Results')
    $termBox.Text = $game.Name

    $run = {
        param([bool]$exact)
        $results.Children.Clear()
        $noteBlock.Text = 'Searching...'
        $fw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        $found = Find-Art $game $termBox.Text.Trim() $exact
        foreach ($c in $found.Items) {
            $bmp = New-Object Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [uri]$c.Thumb; $bmp.DecodePixelWidth = 300; $bmp.EndInit()
            $img = New-Object Windows.Controls.Image
            $img.Source = $bmp; $img.Width = 300; $img.Height = 140; $img.Stretch = 'Uniform'
            $cap = New-Object Windows.Controls.TextBlock
            $cap.Text = $c.Label; $cap.Width = 300; $cap.TextTrimming = 'CharacterEllipsis'; $cap.Foreground = '#B4BCCC'; $cap.Margin = '0,4,0,0'
            $sp = New-Object Windows.Controls.StackPanel
            [void]$sp.Children.Add($img); [void]$sp.Children.Add($cap)
            $btn = New-Object Windows.Controls.Button
            $btn.Content = $sp; $btn.Tag = $c.Url; $btn.Margin = '6'; $btn.Padding = '6'
            $btn.Background = '#161A21'; $btn.BorderBrush = '#262C38'; $btn.Cursor = 'Hand'; $btn.ToolTip = $c.Url
            $btn.Add_Click({ $script:finderPick = $this.Tag; $fw.Close() })
            [void]$results.Children.Add($btn)
        }
        $noteBlock.Text = if ($found.Items.Count) { "$($found.Items.Count) images found. $($found.Note)" } else { "No images found - try a different name. $($found.Note)" }
    }

    $fw.FindName('SearchBtn').Add_Click({ & $run $false })
    $termBox.Add_KeyDown({ if ($_.Key -eq 'Return') { & $run $false } })
    $fw.Add_ContentRendered({ & $run $true })
    if ($Test) {
        # Screenshot mode: show off-screen, run the search and wait for the thumbnails to download
        $fw.WindowStartupLocation = 'Manual'; $fw.Left = -20000; $fw.Top = -20000; $fw.ShowActivated = $false; $fw.ShowInTaskbar = $false
        $fw.Show()
        $fw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ContextIdle)
        if ($script:FinderTerm) { $termBox.Text = $script:FinderTerm; & $run $false }
        for ($i = 0; $i -lt 60; $i++) {
            $fw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background); Start-Sleep -Milliseconds 250
            $busy = @($results.Children | Where-Object { $_.Content.Children[0].Source.IsDownloading })
            if ($i -gt 4 -and $busy.Count -eq 0) { break }
        }
        return $fw
    }
    [void]$fw.ShowDialog()
}

$ui.FindBtn.Add_Click({
    $g = Selected-Game
    if (-not $g) { Set-Status 'Pick a game on the left first.' $true; return }
    Show-Finder $g | Out-Null
    if ($script:finderPick) {
        $ui.SourceBox.Text = $script:finderPick
        Set-Status 'Loading preview...'
        try { Show-Preview $script:finderPick; Set-Status 'Preview of the new image. Click "Use image" to use it.' }
        catch { Set-Status "Couldn't load that image: $($_.Exception.Message)" $true }
    }
})

$ui.KeyBtn.Add_Click({
    Add-Type -AssemblyName Microsoft.VisualBasic
    $current = Get-SgdbKey
    $k = [Microsoft.VisualBasic.Interaction]::InputBox("Paste your SteamGridDB API key.`n`nGet one free: sign in at steamgriddb.com, then Preferences > API.", 'SteamGridDB key', $current).Trim()
    if (-not $k -or $k -eq $current) { return }
    Set-SgdbKey $k
    Set-Status 'Checking key...'
    try { Invoke-Sgdb 'search/autocomplete/portal' | Out-Null; Set-Status 'SteamGridDB key saved and working.' }
    catch { Set-Status "Key saved, but SteamGridDB rejected it: $($_.Exception.Message)" $true }
})

function Get-ScrollViewer($el) {
    if ($el -is [Windows.Controls.ScrollViewer]) { return $el }
    for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($el); $i++) {
        $r = Get-ScrollViewer ([Windows.Media.VisualTreeHelper]::GetChild($el, $i))
        if ($r) { return $r }
    }
    return $null
}

function Show-Order {
    [xml]$ox = (@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Library order" Width="880" Height="720" MinWidth="740" MinHeight="480" Background="#0E1014" Foreground="#E8EBF2"
        FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterOwner">
  <Window.Resources>__THEME__</Window.Resources>
  <DockPanel Margin="16">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#B4BCCC" Margin="0,0,0,12"
      Text="Tick a game to pin it, and drag games to reorder. Pinned games show first in Pimax Play, in this order. Unticked games follow in Pimax's own order. Tip: Pin all, then drag, to control the whole library."/>
    <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,4">
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoPin}" x:Name="PinAll" Content="Pin all" Margin="0,0,6,6"/>
      <Button x:Name="UnpinAll" Content="Unpin all" Margin="0,0,6,6"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoSort}" x:Name="SortAZ" Content="Sort A-Z" Margin="0,0,18,6"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoUp}" x:Name="Up" Content="Move up" Margin="0,0,6,6"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoDown}" x:Name="Down" Content="Move down" Margin="0,0,6,6"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoTop}" x:Name="Top" Content="Move to top" Margin="0,0,6,6"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoBottom}" x:Name="Bottom" Content="Move to bottom" Margin="0,0,6,6"/>
    </WrapPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <Button x:Name="Cancel" DockPanel.Dock="Right" Content="Cancel" Margin="8,0,0,0"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoCheck}" x:Name="Save" DockPanel.Dock="Right" Content="Save and restart Pimax Play"
              Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold"/>
      <TextBlock x:Name="Count" VerticalAlignment="Center" Foreground="#8B93A5"/>
    </DockPanel>
    <ListBox x:Name="Order" AllowDrop="True"/>
  </DockPanel>
</Window>
'@).Replace('__THEME__', $ThemeXaml)
    $script:ow = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $ox))
    if ($window.IsLoaded) { $script:ow.Owner = $window }
    if ($script:AppIcon) { $script:ow.Icon = $script:AppIcon }
    $script:ow.Add_SourceInitialized({ Set-DarkTitleBar $this })
    $script:lb = $script:ow.FindName('Order'); $script:count = $script:ow.FindName('Count')

    $games = @(Get-PimaxGames -WithPending | ForEach-Object { $_ | Add-Member -NotePropertyName Id -NotePropertyValue (Get-GameId $_) -PassThru })
    $pinned = @(Get-PinnedIds)
    $byId = @{}; foreach ($g in $games) { $byId[$g.Id] = $g }
    $removing = Get-PendingRemovedIds
    $script:unknownPins = @($pinned | Where-Object { -not $byId.ContainsKey($_) -and $removing -notcontains $_ })
    $ordered = @($pinned | Where-Object { $byId.ContainsKey($_) } | ForEach-Object { $byId[$_] })
    $ordered += @($games | Where-Object { $pinned -notcontains $_.Id } | Sort-Object { Get-PimaxOrderKey $_ $_.Id })

    $script:updateCount = {
        $n = @($script:lb.Items | Where-Object { $_.Tag.Check.IsChecked }).Count
        $script:count.Text = "$n of $($script:lb.Items.Count) pinned"
    }
    foreach ($g in $ordered) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.IsChecked = ($pinned -contains $g.Id); $cb.VerticalAlignment = 'Center'; $cb.Margin = '0,0,10,0'; $cb.ToolTip = 'Tick to pin this game (pinned games show first, in this order)'
        $cb.Add_Click({ & $script:updateCount })
        $name = New-Object Windows.Controls.TextBlock
        $name.Text = $g.Name; $name.VerticalAlignment = 'Center'
        $src = New-Object Windows.Controls.TextBlock
        $src.Text = "   $($g.Source)"; $src.Foreground = '#7A8397'; $src.VerticalAlignment = 'Center'
        $grip = New-Object Windows.Controls.TextBlock
        $grip.Text = [string][char]0x2261; $grip.Foreground = '#777'; $grip.FontSize = 16; $grip.Margin = '0,0,10,0'; $grip.VerticalAlignment = 'Center'
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        foreach ($c in $grip, $cb, $name, $src) { [void]$row.Children.Add($c) }
        $item = New-Object Windows.Controls.ListBoxItem
        $item.Content = $row; $item.Padding = '6,4'; $item.Cursor = 'SizeAll'; $item.BorderThickness = '0,2,0,2'; $item.BorderBrush = 'Transparent'
        $item.Tag = [pscustomobject]@{ Game = $g; Check = $cb }
        [void]$script:lb.Items.Add($item)
    }
    & $script:updateCount

    $script:findItem = {
        param($el)
        while ($el -and -not ($el -is [Windows.Controls.ListBoxItem])) {
            if ($el -is [Windows.Controls.CheckBox]) { return $null }
            $el = if ($el -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
        }
        return $el
    }
    # The row under the mouse (including over its checkbox) - used while dragging
    $script:itemAt = {
        param($el)
        while ($el -and -not ($el -is [Windows.Controls.ListBoxItem])) {
            $el = if ($el -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
        }
        return $el
    }

    # Drag visuals: a floating label with the game's name, and a blue line where it will land
    $ghostText = New-Object Windows.Controls.TextBlock; $ghostText.Foreground = 'White'; $ghostText.FontWeight = 'SemiBold'
    $ghostBox = New-Object Windows.Controls.Border
    $ghostBox.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromArgb(235, 47, 107, 255))
    $ghostBox.BorderBrush = '#A5C0FF'; $ghostBox.BorderThickness = '1'; $ghostBox.CornerRadius = '4'; $ghostBox.Padding = '10,5'
    $ghostBox.Child = $ghostText
    $script:orderGhost = New-Object Windows.Controls.Primitives.Popup
    $script:orderGhost.Child = $ghostBox; $script:orderGhost.AllowsTransparency = $true; $script:orderGhost.IsHitTestVisible = $false
    $script:orderGhost.PlacementTarget = $script:lb; $script:orderGhost.Placement = 'Relative'
    $script:orderGhostText = $ghostText
    $script:orderMark = $null

    $script:clearMark = {
        if ($script:orderMark) { $script:orderMark.BorderThickness = '0,2,0,2'; $script:orderMark.BorderBrush = 'Transparent'; $script:orderMark = $null }
    }
    # Moves the label to the mouse and marks where the dragged game would land
    $script:dragFeedback = {
        param($pos, $over)
        $script:orderGhost.HorizontalOffset = $pos.X + 14; $script:orderGhost.VerticalOffset = $pos.Y + 6
        $src = $script:orderDragging
        if (-not $over -or $over -eq $src) { & $script:clearMark; return }
        if ($over -ne $script:orderMark) { & $script:clearMark }
        $below = $script:lb.Items.IndexOf($src) -lt $script:lb.Items.IndexOf($over)
        $over.BorderBrush = '#5B8CFF'
        $over.BorderThickness = $(if ($below) { '0,0,0,4' } else { '0,4,0,0' })
        $script:orderMark = $over
    }

    $script:orderDrag = $null
    $script:lb.Add_PreviewMouseLeftButtonDown({ $script:orderDrag = & $script:findItem $_.OriginalSource; $script:orderStart = $_.GetPosition($script:lb) })
    $script:lb.Add_PreviewMouseMove({
        if ($_.LeftButton -ne 'Pressed' -or -not $script:orderDrag) { return }
        $p = $_.GetPosition($script:lb)
        if ([Math]::Abs($p.Y - $script:orderStart.Y) -lt 5 -and [Math]::Abs($p.X - $script:orderStart.X) -lt 5) { return }
        $it = $script:orderDrag; $script:orderDrag = $null
        $script:orderDragging = $it
        $script:orderGhostText.Text = [string][char]0x2261 + '  ' + $it.Tag.Game.Name
        $it.Opacity = 0.35
        & $script:dragFeedback $p $null
        $script:orderGhost.IsOpen = $true
        try { [void][Windows.DragDrop]::DoDragDrop($script:lb, $it, [Windows.DragDropEffects]::Move) }
        finally {
            $script:orderGhost.IsOpen = $false
            $it.Opacity = 1
            & $script:clearMark
            $script:orderDragging = $null
        }
    })
    $script:lb.Add_DragLeave({ & $script:clearMark })
    # Replace Windows' drag pointer (arrow with a box) with a plain arrow; the name label shows what is moving
    $script:lb.Add_GiveFeedback({
        $_.UseDefaultCursors = $false
        [Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::Arrow)
        $_.Handled = $true
    })
    $script:lb.Add_Drop({
        $srcItem = $_.Data.GetData([Windows.Controls.ListBoxItem])
        if (-not $srcItem) { return }
        $target = & $script:itemAt $_.OriginalSource
        $to = if ($target) { $script:lb.Items.IndexOf($target) } else { $script:lb.Items.Count - 1 }
        if ($target -eq $srcItem) { return }
        $script:lb.Items.Remove($srcItem)
        if ($to -gt $script:lb.Items.Count) { $to = $script:lb.Items.Count }
        $script:lb.Items.Insert($to, $srcItem)
        $script:lb.SelectedItem = $srcItem
    })
    # Scroll the list while dragging near its top or bottom edge (faster the closer to the edge)
    $script:orderSv = $null; $script:orderLastScroll = 0
    $script:lb.Add_DragOver({
        $_.Effects = [Windows.DragDropEffects]::Move
        & $script:dragFeedback ($_.GetPosition($this)) (& $script:itemAt $_.OriginalSource)
        if (-not $script:orderSv) { $script:orderSv = Get-ScrollViewer $this }
        $sv = $script:orderSv; if (-not $sv) { return }
        $y = $_.GetPosition($this).Y; $zone = 50; $h = $this.ActualHeight
        $dir = 0; $dist = 0
        if ($y -lt $zone) { $dir = -1; $dist = $zone - $y } elseif ($y -gt $h - $zone) { $dir = 1; $dist = $y - ($h - $zone) }
        if ($dir -eq 0) { return }
        $interval = 40 + (1 - [Math]::Min(1, $dist / $zone)) * 160
        $now = [Environment]::TickCount
        if ($now - $script:orderLastScroll -lt $interval) { return }
        $script:orderLastScroll = $now
        if ($dir -lt 0) { $sv.LineUp() } else { $sv.LineDown() }
    })

    $script:move = {
        param([int]$delta)
        $it = $script:lb.SelectedItem; if (-not $it) { return }
        $i = $script:lb.Items.IndexOf($it); $j = $i + $delta
        if ($j -lt 0 -or $j -ge $script:lb.Items.Count) { return }
        $script:lb.Items.Remove($it); $script:lb.Items.Insert($j, $it); $script:lb.SelectedItem = $it; $script:lb.ScrollIntoView($it)
    }
    $script:ow.FindName('Up').Add_Click({ & $script:move -1 })
    $script:ow.FindName('Down').Add_Click({ & $script:move 1 })
    $script:moveTo = {
        param([bool]$toTop)
        $it = $script:lb.SelectedItem; if (-not $it) { return }
        $script:lb.Items.Remove($it)
        if ($toTop) { $script:lb.Items.Insert(0, $it) } else { [void]$script:lb.Items.Add($it) }
        $script:lb.SelectedItem = $it; $script:lb.ScrollIntoView($it)
    }
    $script:ow.FindName('Top').Add_Click({ & $script:moveTo $true })
    $script:ow.FindName('Bottom').Add_Click({ & $script:moveTo $false })
    $script:ow.FindName('PinAll').Add_Click({ foreach ($it in $script:lb.Items) { $it.Tag.Check.IsChecked = $true }; & $script:updateCount })
    $script:ow.FindName('UnpinAll').Add_Click({ foreach ($it in $script:lb.Items) { $it.Tag.Check.IsChecked = $false }; & $script:updateCount })
    $script:ow.FindName('SortAZ').Add_Click({
        $sorted = @($script:lb.Items | Sort-Object { $_.Tag.Game.Name })
        $script:lb.Items.Clear(); foreach ($it in $sorted) { [void]$script:lb.Items.Add($it) }
    })
    $script:ow.FindName('Cancel').Add_Click({ $script:ow.Close() })
    $script:ow.FindName('Save').Add_Click({
        $ids = @($script:lb.Items | Where-Object { $_.Tag.Check.IsChecked } | ForEach-Object { $_.Tag.Game.Id }) + $script:unknownPins
        $client = Get-ClientPath
        try {
            $waiting = $script:Pending.Count
            if ($waiting) {
                # Games waiting to be added or removed need the full stop, so do the order in the same restart
                [void](Invoke-WhilePimaxStopped { Save-PinnedOrder $ids })
            } else {
                Save-PinnedOrder $ids
                Start-Sleep -Seconds 1
                if (Test-Path $client) { Start-Process $client }
            }
            Save-AutoSnapshot
            $script:orderResult = "Library order saved ($($ids.Count) pinned)" + $(if ($waiting) { " and $script:LastApplied waiting change(s) applied" } else { '' }) + ". Pimax Play restarted."
            $script:ow.Close()
        } catch {
            [Windows.MessageBox]::Show("Couldn't save the order: $($_.Exception.Message)", 'Library order', 'OK', 'Error') | Out-Null
            if (Test-Path $client) { Start-Process $client }
        }
    })
    $script:orderResult = $null
    if ($Test) { return @($script:lb.Items | ForEach-Object { '{0} {1} ({2})' -f $(if ($_.Tag.Check.IsChecked) { '[x]' } else { '[ ]' }), $_.Tag.Game.Name, $_.Tag.Game.Id }) }
    if ($script:Capture) { $script:orderWin = $script:ow; return }
    [void]$script:ow.ShowDialog()
}

$ui.OrderBtn.Add_Click({
    try { Show-Order } catch { Set-Status "Library order failed: $($_.Exception.Message)" $true; return }
    if ($script:orderResult) { Fill-List; Set-Status $script:orderResult }
})

# ---------- Game settings window ----------
function New-DarkWindow([string]$title, [int]$w, [int]$h, [string]$body) {
    $title = [Security.SecurityElement]::Escape($title)
    [xml]$x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$title" Width="$w" Height="$h" MinWidth="560" MinHeight="420" Background="#0E1014" Foreground="#E8EBF2"
        FontFamily="Segoe UI" FontSize="13" WindowStartupLocation="CenterOwner">
  <Window.Resources>$ThemeXaml</Window.Resources>
  $body
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $x))
    if ($window.IsLoaded) { $win.Owner = $window }
    if ($script:AppIcon) { $win.Icon = $script:AppIcon }
    $win.Add_SourceInitialized({ Set-DarkTitleBar $this })
    return $win
}

# Checklist of games; returns the ticked game IDs (or $null if cancelled)
function Select-Games([string]$title, [string]$prompt, [string[]]$exclude) {
    $script:pw = New-DarkWindow $title 480 600 @'
  <DockPanel Margin="14">
    <TextBlock x:Name="Prompt" DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#B4BCCC" Margin="0,0,0,8"/>
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="All" Content="Select all"/><Button x:Name="None" Content="Select none" Margin="6,0,0,0"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoCheck}" x:Name="Ok" Content="OK" Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold"/>
      <Button x:Name="Cancel" Content="Cancel" Margin="8,0,0,0"/>
    </StackPanel>
    <ListBox x:Name="List" Background="#161A21" Foreground="#E8EBF2" BorderBrush="#262C38"/>
  </DockPanel>
'@
    $script:pw.FindName('Prompt').Text = $prompt
    $script:list = $script:pw.FindName('List')
    foreach ($g in ($script:gsGames | Where-Object { $exclude -notcontains $_.Id } | Sort-Object Name)) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = "{0}   ({1})" -f $g.Name, $g.Source; $cb.Tag = $g.Id; $cb.Margin = '2,4'
        [void]$script:list.Items.Add($cb)
    }
    $script:pickResult = $null
    $script:pw.FindName('All').Add_Click({ foreach ($c in $script:list.Items) { $c.IsChecked = $true } })
    $script:pw.FindName('None').Add_Click({ foreach ($c in $script:list.Items) { $c.IsChecked = $false } })
    $script:pw.FindName('Cancel').Add_Click({ $script:pw.Close() })
    $script:pw.FindName('Ok').Add_Click({ $script:pickResult = @($script:list.Items | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag }); $script:pw.Close() })
    [void]$script:pw.ShowDialog()
    return $script:pickResult
}

function Show-GameSettings([string]$startId) {
    $script:sw = New-DarkWindow 'Game settings' 1180 720 @'
  <Grid Margin="14">
    <Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <DockPanel Grid.Column="0">
      <TextBlock DockPanel.Dock="Top" Text="Games" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,8"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoTrash}" x:Name="Leftovers" DockPanel.Dock="Bottom" Content="Remove leftover settings..." Margin="0,8,0,0"/>
      <ListBox x:Name="Targets" Background="#161A21" Foreground="#E8EBF2" BorderBrush="#262C38"/>
    </DockPanel>
    <DockPanel Grid.Column="2">
      <TextBlock x:Name="Title" DockPanel.Dock="Top" FontSize="18" FontWeight="SemiBold"/>
      <TextBlock x:Name="Info" DockPanel.Dock="Top" Foreground="#8B93A5" TextWrapping="Wrap" Margin="0,2,0,10"/>
      <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoSave}" x:Name="Save" DockPanel.Dock="Right" Content="Save all changes" Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold"/>
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoClose}" x:Name="DiscardAll" DockPanel.Dock="Right" Content="Discard all" Margin="0,0,8,0"/>
        <StackPanel Orientation="Horizontal">
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoUndo}" x:Name="Revert" Content="Undo this game"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoRefresh}" x:Name="Reset" Content="Reset to global" Margin="8,0,0,0"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoCopy}" x:Name="CopyAll" Content="Copy all settings to..." Margin="8,0,0,0" Background="#2F6BFF" BorderBrush="#5B8CFF"/>
        </StackPanel>
      </DockPanel>
      <ScrollViewer VerticalScrollBarVisibility="Auto"><Grid x:Name="Rows"/></ScrollViewer>
    </DockPanel>
    <TextBlock x:Name="Status" Grid.Row="1" Grid.ColumnSpan="3" Margin="0,10,0,0" Foreground="#4ADE80" TextWrapping="Wrap"
      Text="Tick 'Custom' to give a game its own value. Changes are kept as you move between games; click Save all changes when you're done."/>
  </Grid>
'@
    $script:targets = $script:sw.FindName('Targets'); $rowsGrid = $script:sw.FindName('Rows')
    $script:gsTitle = $script:sw.FindName('Title'); $script:gsInfo = $script:sw.FindName('Info'); $script:gsStatus = $script:sw.FindName('Status')
    $script:gsSaveBtn = $script:sw.FindName('Save'); $script:gsResetBtn = $script:sw.FindName('Reset')
    $script:gsPending = [ordered]@{}
    $script:gsSay = { param([string]$m, [bool]$bad = $false) $script:gsStatus.Foreground = $(if ($bad) { '#F87171' } else { '#4ADE80' }); $script:gsStatus.Text = $m }

    $script:gsGames = @(Get-PimaxGames -WithPending | ForEach-Object { $_ | Add-Member -NotePropertyName Id -NotePropertyValue (Get-GameId $_) -PassThru -Force } | Sort-Object Name)
    $gItem = New-Object Windows.Controls.ListBoxItem
    $gItem.Tag = 'global'; $gItem.FontWeight = 'SemiBold'; $gItem.Padding = '6,5'
    [void]$script:targets.Items.Add($gItem)
    foreach ($g in $script:gsGames) {
        $it = New-Object Windows.Controls.ListBoxItem
        $it.Tag = $g.Id; $it.Padding = '6,5'
        [void]$script:targets.Items.Add($it)
    }

    # Build one row per setting
    foreach ($w in 90, 190, 230, '*', 100) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $(if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { New-Object Windows.GridLength($w) }); if ($w -eq '*') { $cd.MinWidth = 200 }; $rowsGrid.ColumnDefinitions.Add($cd) }
    $script:gsRows = @()
    $r = 0
    foreach ($def in $SettingDefs) {
        $rowsGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
        $row = [pscustomobject]@{ Def = $def; Check = $null; Control = $null; Hint = $null; Apply = $null }
        $cb = New-Object Windows.Controls.CheckBox; $cb.Content = 'Custom'; $cb.VerticalAlignment = 'Center'; $cb.Tag = $row
        $lbl = New-Object Windows.Controls.TextBlock; $lbl.Text = $def.Label; $lbl.VerticalAlignment = 'Center'; $lbl.Margin = '0,0,10,0'
        if ($def.Tip) { $lbl.ToolTip = $def.Tip }
        if ($def.Kind -eq 'choice') {
            $ctl = New-Object Windows.Controls.ComboBox
            foreach ($o in $def.Options) { $ci = New-Object Windows.Controls.ComboBoxItem; $ci.Content = $o[1]; $ci.Tag = [int]$o[0]; [void]$ctl.Items.Add($ci) }
            $ctl.Add_SelectionChanged({ & $script:gsChanged $this.Tag })
        } else {
            $ctl = New-Object Windows.Controls.TextBox; $ctl.Padding = '4,3'
            $ctl.ToolTip = "{0} to {1}" -f $def.Min.ToString($Inv), $def.Max.ToString($Inv)
            $ctl.Add_TextChanged({ & $script:gsChanged $this.Tag })
        }
        $ctl.Tag = $row; $ctl.Margin = '0,5'; $ctl.VerticalAlignment = 'Center'
        $hint = New-Object Windows.Controls.TextBlock; $hint.Foreground = '#7A8397'; $hint.VerticalAlignment = 'Center'; $hint.Margin = '12,0,8,0'; $hint.TextTrimming = 'CharacterEllipsis'
        $ab = New-Object Windows.Controls.Button; $ab.Content = 'Apply to...'; $ab.Padding = '8,3'; $ab.Margin = '0,5'; $ab.Tag = $row
        $ab.ToolTip = "Use this $($def.Label) on other games"
        $ab.Add_Click({ & $script:gsApplyRow $this.Tag })
        $cb.Add_Click({ $this.Tag.Control.IsEnabled = [bool]$this.IsChecked; & $script:gsChanged $this.Tag })
        $row.Check = $cb; $row.Control = $ctl; $row.Hint = $hint; $row.Apply = $ab
        $col = 0
        foreach ($el in $cb, $lbl, $ctl, $hint, $ab) { [Windows.Controls.Grid]::SetRow($el, $r); [Windows.Controls.Grid]::SetColumn($el, $col); [void]$rowsGrid.Children.Add($el); $col++ }
        $script:gsRows += $row
        $r++
    }

    $script:fmtNum = { param($v) ([double]$v).ToString('0.##', $Inv) }
    $script:display = {
        param($def, $v)
        if ($def.Kind -eq 'number') { return (& $script:fmtNum $v) }
        $o = $def.Options | Where-Object { $_[0] -eq [int]$v } | Select-Object -First 1
        if ($o) { return $o[1] } else { return "value $v" }
    }
    $script:setControl = {
        param($row, $v)
        if ($row.Def.Kind -eq 'number') { $row.Control.Text = (& $script:fmtNum $v); return }
        $item = $row.Control.Items | Where-Object { $_.Tag -eq [int]$v } | Select-Object -First 1
        if (-not $item) { $item = New-Object Windows.Controls.ComboBoxItem; $item.Content = "Value $v"; $item.Tag = [int]$v; [void]$row.Control.Items.Add($item) }
        $row.Control.SelectedItem = $item
    }
    $script:getValue = {
        param($row)
        if ($row.Def.Kind -eq 'number') {
            $d = 0.0
            if (-not [double]::TryParse($row.Control.Text.Trim(), [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { throw "$($row.Def.Label): '$($row.Control.Text)' is not a number." }
            if ($d -lt $row.Def.Min -or $d -gt $row.Def.Max) { throw "$($row.Def.Label) must be between $($row.Def.Min.ToString($Inv)) and $($row.Def.Max.ToString($Inv))." }
            return [double]$d
        }
        if (-not $row.Control.SelectedItem) { throw "$($row.Def.Label): pick an option." }
        return [int]$row.Control.SelectedItem.Tag
    }
    # Settings for a target as they will be saved: queued edits if any, otherwise the file on disk
    $script:gsSettingsOf = {
        param([string]$id)
        if ($script:gsPending.Contains($id)) { $src = $script:gsPending[$id] } else { $src = Read-GameSettings $id }
        $m = [ordered]@{}; foreach ($k in $src.Keys) { $m[$k] = $src[$k] }
        return $m
    }
    $script:gsNameOf = { param([string]$id) if ($id -eq 'global') { 'Global settings' } else { ($script:gsGames | Where-Object { $_.Id -eq $id } | Select-Object -First 1).Name } }

    $script:refreshMarks = {
        foreach ($it in $script:targets.Items) {
            $id = [string]$it.Tag
            $unsaved = $script:gsPending.Contains($id) -or ($script:gsDirty -and $id -eq $script:gsTarget)
            if ($id -eq 'global') { $base = 'Global (default for all games)'; $custom = $false }
            else {
                $base = & $script:gsNameOf $id
                if ($script:gsPending.Contains($id)) { $custom = $script:gsPending[$id].Count -gt 0 } else { $custom = Test-Path -LiteralPath (Get-SettingsPath $id) }
            }
            $it.Content = $base + $(if ($custom) { '   *' } else { '' }) + $(if ($unsaved) { '   (unsaved)' } else { '' })
            $it.Foreground = $(if ($unsaved) { '#FB923C' } else { '#E8EBF2' })
            $it.ToolTip = $(if ($id -eq 'global') { 'Default settings for every game' } elseif ($custom) { 'Has its own settings' } else { 'Uses global settings' })
        }
        $n = $script:gsPending.Count
        if ($script:gsDirty -and -not $script:gsPending.Contains($script:gsTarget)) { $n++ }
        $script:gsSaveBtn.Content = $(if ($n) { "Save all changes ($n)" } else { 'Save all changes' })
    }

    $script:gsChanged = {
        param($row)
        if ($script:gsLoading) { return }
        $wasDirty = $script:gsDirty
        $script:gsDirty = $true
        # Picking Low/Medium/High also sets the matching render resolution, as Pimax Play does
        if ($row.Def.Key -eq 'piplay_display_quality_level' -and $row.Control.SelectedItem) {
            $lvl = [int]$row.Control.SelectedItem.Tag
            if ($QualityRates.ContainsKey($lvl)) {
                $rate = $script:gsRows | Where-Object { $_.Def.Key -eq 'runtime_pixels_per_display_pixel_rate' }
                $script:gsLoading = $true
                if ($script:gsTarget -ne 'global') { $rate.Check.IsChecked = $row.Check.IsChecked; $rate.Control.IsEnabled = [bool]$row.Check.IsChecked }
                & $script:setControl $rate $QualityRates[$lvl]
                $script:gsLoading = $false
            }
        }
        if (-not $wasDirty) { & $script:refreshMarks }
    }

    $script:loadTarget = {
        param([string]$id)
        $script:gsLoading = $true
        $script:gsTarget = $id
        $script:gsCurrent = & $script:gsSettingsOf $id
        $glob = & $script:gsSettingsOf 'global'
        $isGlobal = ($id -eq 'global')
        $script:gsTitle.Text = & $script:gsNameOf $id
        $pendingNote = if ($script:gsPending.Contains($id)) { ' Showing your unsaved changes.' } else { '' }
        $script:gsInfo.Text = $(if ($isGlobal) { 'Used by every game that has no custom value for a setting.' }
                       elseif ($script:gsCurrent.Count) { "Has its own settings ($id). Unticked settings use the global value shown on the right." }
                       else { "Uses the global settings for everything. Tick 'Custom' on a setting to give this game its own value." }) + $pendingNote
        foreach ($row in $script:gsRows) {
            $k = $row.Def.Key
            $has = $script:gsCurrent.Contains($k)
            $gv = if ($glob.Contains($k)) { $glob[$k] } else { $row.Def.Default }
            $v = if ($has) { $script:gsCurrent[$k] } elseif ($isGlobal) { $row.Def.Default } else { $gv }
            & $script:setControl $row $v
            $row.Check.Visibility = $(if ($isGlobal) { 'Hidden' } else { 'Visible' })
            $row.Check.IsChecked = ($has -or $isGlobal)
            $row.Control.IsEnabled = ($has -or $isGlobal)
            $row.Hint.Text = if ($isGlobal) { $(if ($has) { '' } else { '(Pimax default)' }) } else { 'Global: ' + (& $script:display $row.Def $gv) }
        }
        $script:gsResetBtn.Content = $(if ($isGlobal) { 'Reset to Pimax defaults' } else { 'Reset to global' })
        $script:gsResetBtn.ToolTip = $(if ($isGlobal) { 'Clear the global settings so Pimax uses its built-in defaults' } else { 'Remove all of this game''s custom settings so it follows the global settings' })
        $script:gsDirty = $false
        $script:gsLoading = $false
        & $script:refreshMarks
    }

    $script:collect = {
        $map = [ordered]@{}
        foreach ($k in $script:gsCurrent.Keys) { $map[$k] = $script:gsCurrent[$k] }
        foreach ($row in $script:gsRows) {
            if ($row.Check.IsChecked -or $script:gsTarget -eq 'global') { $map[$row.Def.Key] = & $script:getValue $row }
            elseif ($map.Contains($row.Def.Key)) { $map.Remove($row.Def.Key) }
        }
        return $map
    }

    # Keep the current game's edits in the queue (throws if a value is invalid)
    $script:gsStash = {
        if (-not $script:gsDirty) { return }
        $map = & $script:collect
        $script:gsPending[$script:gsTarget] = $map
        $script:gsCurrent = $map
        $script:gsDirty = $false
    }

    $script:gsSaveAll = {
        & $script:gsStash
        if ($script:gsPending.Count -eq 0) { & $script:gsSay 'Nothing to save.'; return $true }
        $ids = @($script:gsPending.Keys)
        $n = $ids.Count
        & $script:gsSay "Saving $n game(s) - restarting Pimax..."
        $script:sw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        Backup-SettingsOnce $ids
        $ok = Invoke-WhilePimaxStopped { foreach ($id in $ids) { Write-GameSettings $id $script:gsPending[$id] } }
        Save-AutoSnapshot
        $script:gsPending = [ordered]@{}
        & $script:loadTarget $script:gsTarget
        & $script:gsSay ("Saved changes to $n game(s)." + $(if ($script:LastApplied) { " Also applied $script:LastApplied waiting library change(s)." } else { '' }) + $(if (-not $ok) { ' (Could not restart the Pimax service; restart your PC if it does not apply.)' } else { '' })) (-not $ok)
        return $true
    }

    $script:gsApplyRow = {
        param($row)
        $label = $row.Def.Label
        try {
            $custom = $row.Check.IsChecked -or $script:gsTarget -eq 'global'
            $val = if ($custom) { & $script:getValue $row } else { $null }
        } catch { & $script:gsSay $_.Exception.Message $true; return }
        $what = if ($custom) { "$label = " + (& $script:display $row.Def $val) } else { "$label back to the global value" }
        $ids = Select-Games "Apply $label" "Set $what on these games (saved when you click Save all changes):" @($script:gsTarget)
        if (-not $ids -or $ids.Count -eq 0) { return }
        $key = $row.Def.Key
        foreach ($t in $ids) {
            $m = & $script:gsSettingsOf $t
            if ($custom) { $m[$key] = $val } elseif ($m.Contains($key)) { $m.Remove($key) }
            if ($custom -and $key -eq 'piplay_display_quality_level' -and $QualityRates.ContainsKey([int]$val)) { $m['runtime_pixels_per_display_pixel_rate'] = $QualityRates[[int]$val] }
            $script:gsPending[$t] = $m
        }
        & $script:refreshMarks
        & $script:gsSay "Queued $what for $($ids.Count) game(s). Click Save all changes to apply."
    }

    $script:targets.Add_SelectionChanged({
        $it = $script:targets.SelectedItem
        if ($script:gsSwitching -or -not $it -or $it.Tag -eq $script:gsTarget) { return }
        try { & $script:gsStash }
        catch {
            [Windows.MessageBox]::Show("Fix this before switching games:`n`n$($_.Exception.Message)", 'Game settings', 'OK', 'Warning') | Out-Null
            $script:gsSwitching = $true
            $script:targets.SelectedItem = ($script:targets.Items | Where-Object { $_.Tag -eq $script:gsTarget } | Select-Object -First 1)
            $script:gsSwitching = $false
            return
        }
        & $script:loadTarget ([string]$it.Tag)
        & $script:gsSay "Showing $($script:gsTitle.Text)."
    })

    $script:sw.FindName('Revert').Add_Click({
        if ($script:gsPending.Contains($script:gsTarget)) { $script:gsPending.Remove($script:gsTarget) }
        & $script:loadTarget $script:gsTarget
        & $script:gsSay "Undid unsaved changes to $($script:gsTitle.Text)."
    })

    $script:gsResetBtn.Add_Click({
        $script:gsPending[$script:gsTarget] = [ordered]@{}
        & $script:loadTarget $script:gsTarget
        $what = if ($script:gsTarget -eq 'global') { 'Global reset to Pimax defaults' } else { "$($script:gsTitle.Text) reset to the global settings" }
        & $script:gsSay "$what. Click Save all changes to apply, or Undo this game to cancel."
    })

    $script:sw.FindName('DiscardAll').Add_Click({
        if (-not $script:gsPending.Count -and -not $script:gsDirty) { & $script:gsSay 'No unsaved changes.'; return }
        $a = [Windows.MessageBox]::Show('Discard all unsaved changes?', 'Game settings', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        $script:gsPending = [ordered]@{}
        & $script:loadTarget $script:gsTarget
        & $script:gsSay 'All unsaved changes discarded.'
    })

    $script:gsSaveBtn.Add_Click({
        try { [void](& $script:gsSaveAll) } catch { & $script:gsSay "Couldn't save: $($_.Exception.Message)" $true }
    })

    $script:sw.FindName('CopyAll').Add_Click({
        try { $map = & $script:collect } catch { & $script:gsSay $_.Exception.Message $true; return }
        $src = $script:gsTitle.Text
        $ids = Select-Games 'Copy all settings' "Copy every setting shown for $src to these games. Their per-game settings will be replaced when you click Save all changes." @($script:gsTarget)
        if (-not $ids -or $ids.Count -eq 0) { return }
        foreach ($t in $ids) { $copy = [ordered]@{}; foreach ($k in $map.Keys) { $copy[$k] = $map[$k] }; $script:gsPending[$t] = $copy }
        & $script:refreshMarks
        & $script:gsSay "Queued a copy of $src's settings for $($ids.Count) game(s). Click Save all changes to apply."
    })

    $script:sw.FindName('Leftovers').Add_Click({
        if ($script:gsPending.Count -or $script:gsDirty) { & $script:gsSay 'Save or discard your changes first, then remove leftovers.' $true; return }
        $known = @('global') + @($script:gsGames | ForEach-Object { $_.Id })
        $orphans = @(Get-ChildItem $AppConfigDir -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $known -notcontains $_.BaseName })
        if ($orphans.Count -eq 0) { & $script:gsSay 'No leftover settings files - every file belongs to a game in your library.'; return }
        $names = ($orphans | ForEach-Object { '  ' + $_.Name }) -join "`n"
        $a = [Windows.MessageBox]::Show("These settings files belong to games no longer in your Pimax library (for example a game that was removed and imported again):`n`n$names`n`nMove them to the backup folder?", 'Remove leftover settings', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        $dest = Join-Path $BackupDir 'settings\leftover'
        try {
            & $script:gsSay 'Removing leftover settings - restarting Pimax...'
            $ok = Invoke-WhilePimaxStopped {
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                foreach ($f in $orphans) { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $f.Name) -Force }
            }
            Save-AutoSnapshot
            & $script:gsSay "Moved $($orphans.Count) leftover file(s) to $dest."
        } catch { & $script:gsSay "Couldn't remove leftovers: $($_.Exception.Message)" $true }
    })

    $script:sw.Add_Closing({
        try { & $script:gsStash } catch { }
        if ($script:gsPending.Count -eq 0 -and -not $script:gsDirty) { return }
        $a = [Windows.MessageBox]::Show("Save your changes to $($script:gsPending.Count) game(s) before closing?", 'Game settings', 'YesNoCancel', 'Question')
        if ($a -eq 'Cancel') { $_.Cancel = $true; return }
        if ($a -eq 'Yes') {
            try { [void](& $script:gsSaveAll) } catch { & $script:gsSay "Couldn't save: $($_.Exception.Message)" $true; $_.Cancel = $true }
        }
    })

    $start = $script:targets.Items | Where-Object { $_.Tag -eq $startId } | Select-Object -First 1
    if (-not $start) { $start = $script:targets.Items[0] }
    $script:gsTarget = $null; $script:gsDirty = $false; $script:gsSwitching = $false
    $script:targets.SelectedItem = $start
    if ($script:Capture -or $Test) { return $script:sw }
    [void]$script:sw.ShowDialog()
}

$ui.SettingsBtn.Add_Click({
    $g = Selected-Game
    $id = if ($g) { Get-GameId $g } else { 'global' }
    $before = $script:Pending.Count
    try { Show-GameSettings $id } catch { Set-Status "Game settings failed: $($_.Exception.Message)" $true }
    if ($script:Pending.Count -ne $before) { Fill-List }
})


# ---------- Performance window ----------
function Show-Performance([string]$startId) {
    $script:pw2 = New-DarkWindow 'Performance' 1180 760 @'
  <Grid Margin="14">
    <Grid.ColumnDefinitions><ColumnDefinition Width="320"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <DockPanel Grid.Column="0">
      <TextBlock DockPanel.Dock="Top" Text="Games" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,8"/>
      <Border DockPanel.Dock="Bottom" Margin="0,10,0,0" Background="#14171E" BorderBrush="#222733" BorderThickness="1" CornerRadius="10" Padding="12,10">
        <StackPanel>
          <TextBlock Text="Performance Guard" FontWeight="SemiBold" FontSize="14"/>
          <TextBlock Foreground="#8B93A5" TextWrapping="Wrap" Margin="0,3,0,8" FontSize="12"
                     Text="Runs quietly in the tray: puts locked settings back while a game is closed and applies the core and window options when it starts."/>
          <CheckBox x:Name="GuardOn" Content="Run it, and start it with Windows"/>
          <TextBlock x:Name="GuardState" Margin="26,4,0,0" FontSize="12" Foreground="#8B93A5"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoList}" x:Name="OpenLog" Content="Open log" Margin="0,10,0,0" HorizontalAlignment="Left" Padding="10,5"/>
        </StackPanel>
      </Border>
      <ListBox x:Name="Targets" Background="#161A21" Foreground="#E8EBF2" BorderBrush="#262C38"/>
    </DockPanel>
    <DockPanel Grid.Column="2">
      <TextBlock x:Name="Title" DockPanel.Dock="Top" FontSize="18" FontWeight="SemiBold"/>
      <TextBlock x:Name="Info" DockPanel.Dock="Top" Foreground="#8B93A5" TextWrapping="Wrap" Margin="0,2,0,10"/>
      <Border DockPanel.Dock="Top" Background="#14171E" BorderBrush="#222733" BorderThickness="1" CornerRadius="10" Padding="12,10" Margin="0,0,0,10">
        <StackPanel>
          <CheckBox x:Name="PinCores" Content="Run the game on the performance cores only"/>
          <TextBlock x:Name="PinInfo" Margin="26,2,0,8" FontSize="12" Foreground="#8B93A5" TextWrapping="Wrap"/>
          <CheckBox x:Name="KeepWindow" Content="Keep the game's desktop window on screen"/>
          <TextBlock Margin="26,2,0,8" FontSize="12" Foreground="#8B93A5" TextWrapping="Wrap"
                     Text="If the game opens its window off the edge of the monitor (for example where a second screen used to be), it is moved back and made small."/>
          <CheckBox x:Name="LockOn" Content="Lock the settings ticked below"/>
          <TextBlock Margin="26,2,0,0" FontSize="12" Foreground="#8B93A5" TextWrapping="Wrap"
                     Text="While the game is closed, any ticked setting that changed (a game update, a reset, or the in-game menu) is put back. A backup of the file is kept first."/>
        </StackPanel>
      </Border>
      <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoSave}" x:Name="Save" DockPanel.Dock="Right" Content="Save" Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold"/>
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoCheck}" x:Name="SaveApply" DockPanel.Dock="Right" Content="Save &amp; apply now" Margin="0,0,8,0"
                ToolTip="Save, and write the locked settings into the game's file right away (the game must be closed)"/>
        <StackPanel Orientation="Horizontal">
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoGauge}" x:Name="Recommend" Content="Recommended for VR" Background="#2F6BFF" BorderBrush="#5B8CFF"
                  ToolTip="Tick and fill in a VR starting point. Settings without a suggestion are left as they are."/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoDownload}" x:Name="UseCurrent" Content="Use current" Margin="8,0,0,0"
                  ToolTip="Fill the ticked settings with what the game's file has now"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoUndo}" x:Name="Restore" Content="Restore original..." Margin="8,0,0,0"
                  ToolTip="Put the game's settings file back the way it was before this app first changed it, and stop locking it - handy to compare before and after"/>
          <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoFolder}" x:Name="OpenFile" Content="Show file" Margin="8,0,0,0"
                  ToolTip="Open the folder with the game's settings file"/>
        </StackPanel>
      </DockPanel>
      <ScrollViewer VerticalScrollBarVisibility="Auto"><Grid x:Name="Rows" Margin="0,0,8,0"/></ScrollViewer>
    </DockPanel>
    <TextBlock x:Name="Status" Grid.Row="1" Grid.ColumnSpan="3" Margin="0,10,0,0" Foreground="#4ADE80" TextWrapping="Wrap"
      Text="Tick the settings you want to keep, set their values, then Save. Close the game before applying - it rewrites its file when it quits."/>
  </Grid>
'@
    $w = $script:pw2
    $script:pfTargets = $w.FindName('Targets'); $script:pfRowsGrid = $w.FindName('Rows')
    $script:pfTitle = $w.FindName('Title'); $script:pfInfo = $w.FindName('Info'); $script:pfStatus = $w.FindName('Status')
    $script:pfPin = $w.FindName('PinCores'); $script:pfPinInfo = $w.FindName('PinInfo'); $script:pfKeep = $w.FindName('KeepWindow'); $script:pfLock = $w.FindName('LockOn')
    $script:pfGuardOn = $w.FindName('GuardOn'); $script:pfGuardState = $w.FindName('GuardState')
    $script:pfSay = { param([string]$m, [bool]$bad = $false) $script:pfStatus.Foreground = $(if ($bad) { '#F87171' } else { '#4ADE80' }); $script:pfStatus.Text = $m }
    $script:pfCfg = Read-PerfConfig
    $script:pfDirty = $false; $script:pfTarget = $null; $script:pfRows = @()
    $script:pfMask = Get-PCoreMask

    foreach ($pg in ($PerfGames | Sort-Object @{ Expression = { if (Get-PerfConfigPath $_) { 0 } else { 1 } } }, @{ Expression = { [array]::IndexOf($PerfGames, $_) } })) {
        $it = New-Object Windows.Controls.ListBoxItem; $it.Tag = $pg.Id; $it.Padding = '6,6'
        [void]$script:pfTargets.Items.Add($it)
    }
    $script:pfMarks = {
        foreach ($it in $script:pfTargets.Items) {
            $pg = Get-PerfGame ([string]$it.Tag); $path = Get-PerfConfigPath $pg
            $e = if ($script:pfCfg.games.Contains($pg.Id)) { $script:pfCfg.games[$pg.Id] } else { $null }
            $on = $e -and ($e.lock -or $e.pinCores -or $e.keepWindow)
            $it.Content = $pg.Name + $(if ($on) { '   *' } else { '' }) + $(if (-not $path) { '   (not installed)' } else { '' })
            $it.Foreground = $(if (-not $path) { '#6B7385' } else { '#E8EBF2' })
            $it.ToolTip = $(if (-not $path) { 'Its settings file was not found on this PC' } elseif ($on) { 'Performance options are on' } else { '' })
        }
    }
    $script:pfGuardShow = {
        $t = Get-GuardTask; $running = Test-GuardRunning
        $script:pfGuardLoading = $true
        $script:pfGuardOn.IsChecked = [bool]($t -and $t.State -ne 'Disabled')
        $script:pfGuardLoading = $false
        $script:pfGuardState.Text = $(if ($running) { 'Running now (tray icon by the clock)' } else { 'Not running' })
        $script:pfGuardState.Foreground = $(if ($running) { '#4ADE80' } else { '#8B93A5' })
    }

    # Fill the rows for one game
    $script:pfLoad = {
        param([string]$id)
        $pg = Get-PerfGame $id; $script:pfTarget = $id
        $e = Get-PerfEntry $script:pfCfg $id
        $path = Get-PerfConfigPath $pg
        $cur = @{}; if ($path) { try { $cur = Read-PerfValues $pg $path } catch { & $script:pfSay "Couldn't read $path - $($_.Exception.Message)" $true } }
        $script:pfCur = $cur; $script:pfPath = $path
        $running = (Get-PerfProcesses $pg).Count -gt 0
        $script:pfTitle.Text = $pg.Name
        $script:pfInfo.Text = $(if ($path) { "Settings file: $path" + $(if ($running) { "`nThe game is running now - changes to its file are made after it closes." } else { '' }) }
                                else { "Not installed on this PC, so there's nothing to set up here. (No settings file in:`n" + (($pg.Configs | ForEach-Object { if ($_ -is [scriptblock]) { 'the game''s install folder' } else { $_ } }) -join "`n") + ")`nIf it is installed, start it once so it creates the file." }) 
        $script:pfLoading = $true
        $script:pfPin.IsChecked = [bool]$e.pinCores; $script:pfKeep.IsChecked = [bool]$e.keepWindow; $script:pfLock.IsChecked = [bool]$e.lock
        $script:pfPin.IsEnabled = [bool]$script:pfMask
        $script:pfPinInfo.Text = $(if ($script:pfMask) { "Your CPU has performance and efficiency cores. The game is kept on the performance cores ($(Get-PCoreText $script:pfMask)) and given a slightly higher priority, so its main thread never lands on a slower core." }
                                   else { "Not needed on this PC: all its CPU cores are the same type." })
        $script:pfRowsGrid.Children.Clear(); $script:pfRowsGrid.RowDefinitions.Clear(); $script:pfRowsGrid.ColumnDefinitions.Clear()
        foreach ($cw in 70, 280, 150, '*') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $(if ($cw -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { New-Object Windows.GridLength($cw) }); $script:pfRowsGrid.ColumnDefinitions.Add($cd) }
        $script:pfRows = @(); $r = 0; $lastGroup = $null
        foreach ($def in $pg.Settings) {
            if ($def.Group -ne $lastGroup) {
                $script:pfRowsGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
                $h = New-Object Windows.Controls.TextBlock; $h.Text = $def.Group.ToUpper(); $h.Foreground = '#5B8CFF'; $h.FontSize = 11; $h.FontWeight = 'SemiBold'; $h.Margin = $(if ($r) { '0,14,0,4' } else { '0,0,0,4' })
                [Windows.Controls.Grid]::SetRow($h, $r); [Windows.Controls.Grid]::SetColumnSpan($h, 4); [void]$script:pfRowsGrid.Children.Add($h)
                $r++; $lastGroup = $def.Group
            }
            $script:pfRowsGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
            $row = [pscustomobject]@{ Def = $def; Check = $null; Box = $null }
            $cb = New-Object Windows.Controls.CheckBox; $cb.Content = 'Lock'; $cb.VerticalAlignment = 'Center'; $cb.Tag = $row
            $lbl = New-Object Windows.Controls.TextBlock; $lbl.Text = $def.Label; $lbl.VerticalAlignment = 'Center'; $lbl.Margin = '0,0,10,0'; $lbl.TextTrimming = 'CharacterEllipsis'
            $lbl.ToolTip = $(if ($def.Tip) { "$($def.Tip)`n`n$($def.Key)" } else { $def.Key })
            $tb = New-Object Windows.Controls.TextBox; $tb.Padding = '4,3'; $tb.Margin = '0,4'; $tb.Tag = $row
            $has = $cur.ContainsKey($def.Key)
            $locked = $e.values.Contains($def.Key)
            $tb.Text = $(if ($locked) { [string]$e.values[$def.Key] } elseif ($has) { [string]$cur[$def.Key] } else { '' })
            $hint = New-Object Windows.Controls.TextBlock; $hint.VerticalAlignment = 'Center'; $hint.Margin = '12,0,0,0'; $hint.TextTrimming = 'CharacterEllipsis'
            $hint.Text = $(if ($has) { "In the game now: $($cur[$def.Key])" } elseif ($path) { 'Not in the file' } else { '' })
            $hint.Foreground = $(if ($locked -and $has -and [string]$cur[$def.Key] -ne [string]$e.values[$def.Key]) { '#FB923C' } else { '#7A8397' })
            if ($def.Recommended) { $hint.ToolTip = "VR starting point: $($def.Recommended)" }
            $cb.IsChecked = $locked; $tb.IsEnabled = $locked
            $cb.IsEnabled = [bool]$path -and ($has -or $pg.Format -eq 'scs')
            $cb.Add_Click({ $this.Tag.Box.IsEnabled = [bool]$this.IsChecked; if (-not $script:pfLoading) { $script:pfDirty = $true } })
            $tb.Add_TextChanged({ if (-not $script:pfLoading) { $script:pfDirty = $true } })
            $row.Check = $cb; $row.Box = $tb
            $col = 0
            foreach ($el in $cb, $lbl, $tb, $hint) { [Windows.Controls.Grid]::SetRow($el, $r); [Windows.Controls.Grid]::SetColumn($el, $col); [void]$script:pfRowsGrid.Children.Add($el); $col++ }
            $script:pfRows += $row; $r++
        }
        foreach ($b in 'Recommend', 'UseCurrent', 'OpenFile', 'SaveApply') { $script:pw2.FindName($b).IsEnabled = [bool]$path }
        $orig = Get-PerfOriginal $pg
        $rb = $script:pw2.FindName('Restore'); $rb.IsEnabled = [bool]($path -and $orig)
        $rb.ToolTip = $(if ($orig) { "Put the file back as it was on $($orig.LastWriteTime.ToString('g')), before this app first changed it, and stop locking it - handy to compare before and after" } else { 'Nothing to restore: this app hasn''t changed this game''s file yet' })
        $script:pfLock.IsEnabled = [bool]$path
        $script:pfLoading = $false
    }

    # Copy what's on screen into the in-memory settings (checks the values first)
    $script:pfStore = {
        if (-not $script:pfTarget) { return }
        $e = Get-PerfEntry $script:pfCfg $script:pfTarget
        $vals = [ordered]@{}
        foreach ($row in $script:pfRows) {
            if (-not $row.Check.IsChecked) { continue }
            $v = $row.Box.Text.Trim()
            if (-not $v) { throw "$($row.Def.Label): enter a value, or untick Lock." }
            if ($v.Contains('"') -or $v.Contains("`n")) { throw "$($row.Def.Label): the value can't contain quotes or line breaks." }
            $vals[$row.Def.Key] = $v
        }
        $e.values = $vals; $e.pinCores = [bool]$script:pfPin.IsChecked; $e.keepWindow = [bool]$script:pfKeep.IsChecked; $e.lock = [bool]$script:pfLock.IsChecked
    }
    $script:pfSaveAll = {
        & $script:pfStore
        Save-PerfConfig $script:pfCfg
        $script:pfDirty = $false; & $script:pfMarks
        $e = $script:pfCfg.games[$script:pfTarget]
        $needGuard = @($script:pfCfg.games.Values | Where-Object { ($_.lock -and $_.values.Count) -or $_.pinCores -or $_.keepWindow }).Count -gt 0
        if ($needGuard -and -not (Get-GuardTask | Where-Object { $_.State -ne 'Disabled' })) { return 'Saved. Turn on Performance Guard (bottom left) so these are kept and applied while you play.' }
        return 'Saved. Performance Guard picks the changes up within a few seconds.'
    }

    $script:pfTargets.Add_SelectionChanged({
        $it = $script:pfTargets.SelectedItem
        if (-not $it -or $script:pfSwitching) { return }
        if ($script:pfTarget -and $script:pfTarget -ne [string]$it.Tag) {
            try { & $script:pfStore } catch {
                & $script:pfSay $_.Exception.Message $true
                $script:pfSwitching = $true; $script:pfTargets.SelectedItem = ($script:pfTargets.Items | Where-Object { $_.Tag -eq $script:pfTarget }); $script:pfSwitching = $false
                return
            }
        }
        & $script:pfLoad ([string]$it.Tag)
    })
    foreach ($c in $script:pfPin, $script:pfKeep, $script:pfLock) { $c.Add_Click({ if (-not $script:pfLoading) { $script:pfDirty = $true } }) }

    $w.FindName('Recommend').Add_Click({
        $n = 0
        foreach ($row in $script:pfRows) {
            if ($null -eq $row.Def.Recommended -or -not $row.Check.IsEnabled) { continue }
            $row.Check.IsChecked = $true; $row.Box.IsEnabled = $true; $row.Box.Text = [string]$row.Def.Recommended; $n++
        }
        $script:pfLock.IsChecked = $true
        if ($script:pfMask) { $script:pfPin.IsChecked = $true }
        $script:pfKeep.IsChecked = $true; $script:pfDirty = $true
        & $script:pfSay "Filled in $n VR starting values (hover a setting to see what it does). Check them, then Save."
    })
    $w.FindName('UseCurrent').Add_Click({
        $n = 0
        foreach ($row in $script:pfRows) { if ($row.Check.IsChecked -and $script:pfCur.ContainsKey($row.Def.Key)) { $row.Box.Text = [string]$script:pfCur[$row.Def.Key]; $n++ } }
        $script:pfDirty = $true
        & $script:pfSay $(if ($n) { "$n ticked setting(s) now match the game's file." } else { 'Tick Lock on the settings you want first.' })
    })
    $w.FindName('Restore').Add_Click({
        $pg = Get-PerfGame $script:pfTarget; $orig = Get-PerfOriginal $pg
        if (-not $orig -or -not $script:pfPath) { return }
        if ((Get-PerfProcesses $pg).Count) { & $script:pfSay "Close $($pg.Name) first - it rewrites its settings file when it quits." $true; return }
        $a = [Windows.MessageBox]::Show("Put $($pg.Name)'s settings file back the way it was on $($orig.LastWriteTime.ToString('g')), before Pimax Game Manager first changed it?`n`nLocking is turned off for this game so the guard leaves it alone. Your locked values are kept: to go back to them, tick 'Lock the settings ticked below' and click Save & apply now.", 'Restore original', 'OKCancel', 'Question')
        if ($a -ne 'OK') { return }
        try {
            $dir = Join-Path $PerfBackupDir $pg.Id
            Copy-Item -LiteralPath $script:pfPath (Join-Path $dir ("{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), [IO.Path]::GetFileName($script:pfPath)))
            Copy-Item -LiteralPath $orig.FullName $script:pfPath -Force
            $disk = Read-PerfConfig; $e = Get-PerfEntry $disk $pg.Id; $e.lock = $false; Save-PerfConfig $disk
            $mem = Get-PerfEntry $script:pfCfg $pg.Id; $mem.lock = $false
            Write-PerfLog "$($pg.Name): original settings file restored from the app; locking turned off"
            & $script:pfLoad $pg.Id; & $script:pfMarks
            & $script:pfSay "$($pg.Name) is back to its original settings and no longer locked. To switch back, tick Lock the settings ticked below and click Save & apply now."
        } catch { & $script:pfSay "Couldn't restore: $($_.Exception.Message)" $true }
    })
    $w.FindName('OpenFile').Add_Click({ if ($script:pfPath) { Start-Process explorer.exe -ArgumentList "/select,`"$($script:pfPath)`"" } })
    $w.FindName('OpenLog').Add_Click({ if (-not (Test-Path $PerfLog)) { Write-PerfLog 'Log created' }; Start-Process notepad.exe $PerfLog })
    $w.FindName('Save').Add_Click({ try { & $script:pfSay (& $script:pfSaveAll) } catch { & $script:pfSay $_.Exception.Message $true } })
    $w.FindName('SaveApply').Add_Click({
        try {
            $msg = & $script:pfSaveAll
            $pg = Get-PerfGame $script:pfTarget; $e = $script:pfCfg.games[$pg.Id]
            if (-not $e.values.Count) { & $script:pfSay 'Saved. No settings are ticked, so there was nothing to apply.'; return }
            if ((Get-PerfProcesses $pg).Count) { & $script:pfSay "Saved. $($pg.Name) is running - close it first (it rewrites its file when it quits). Performance Guard applies them once it's closed." $true; return }
            $ch = @(Set-PerfValues $pg $script:pfPath $e.values)
            if ($ch.Count) { Write-PerfLog "$($pg.Name): applied $($ch.Count) setting(s) from the app: $($ch -join '; ')" }
            & $script:pfLoad $pg.Id
            & $script:pfSay $(if ($ch.Count) { "Saved and applied $($ch.Count) setting(s) to $($pg.Name). A backup of the old file is in backups\performance." } else { "Saved. $($pg.Name) already had these values." })
        } catch { & $script:pfSay $_.Exception.Message $true }
    })
    $script:pfGuardOn.Add_Click({
        if ($script:pfGuardLoading) { return }
        try {
            if ($script:pfGuardOn.IsChecked) {
                [void](Register-GuardTask $true); Start-Guard
                $script:pfCfg.guard = $true; Write-PerfLog 'Performance Guard turned on in the app'
                & $script:pfSay 'Performance Guard is on. It starts with Windows and shows an icon in the tray by the clock.'
            } else {
                if (Get-GuardTask) { [void](Disable-ScheduledTask -TaskName $GuardTask) }
                Stop-Guard
                $script:pfCfg.guard = $false; Write-PerfLog 'Performance Guard turned off in the app'
                & $script:pfSay 'Performance Guard is off. Locked settings are no longer put back.'
            }
            # Save only the on/off switch; other edits stay unsaved until Save
            $disk = Read-PerfConfig; $disk.guard = $script:pfCfg.guard; Save-PerfConfig $disk
        } catch { & $script:pfSay "Couldn't change Performance Guard: $($_.Exception.Message)" $true }
        Start-Sleep -Milliseconds 700; & $script:pfGuardShow
    })
    $w.Add_Closing({
        param($s, $ev)
        if (-not $script:pfDirty -or $Test) { return }
        $a = [Windows.MessageBox]::Show('Save your Performance changes before closing?', 'Performance', 'YesNoCancel', 'Question')
        if ($a -eq 'Cancel') { $ev.Cancel = $true; return }
        if ($a -eq 'Yes') { try { [void](& $script:pfSaveAll) } catch { [Windows.MessageBox]::Show($_.Exception.Message, 'Performance', 'OK', 'Warning') | Out-Null; $ev.Cancel = $true } }
    })

    & $script:pfMarks; & $script:pfGuardShow
    $start = $script:pfTargets.Items | Where-Object { $_.Tag -eq $startId } | Select-Object -First 1
    if (-not $start) { $start = $script:pfTargets.Items | Where-Object { Get-PerfConfigPath (Get-PerfGame ([string]$_.Tag)) } | Select-Object -First 1 }
    if (-not $start) { $start = $script:pfTargets.Items[0] }
    $script:pfTargets.SelectedItem = $start
    if ($script:Capture -or $Test) { return $script:pw2 }
    [void]$script:pw2.ShowDialog()
}

# Which Performance game (if any) a Pimax library entry is, by its .exe or Steam app id
function Get-PerfIdForGame($game) {
    if (-not $game) { return $null }
    $route = (Get-Route $game)
    $steam = @{ '270880' = 'ats'; '227300' = 'ets2'; '2537590' = 'msfs2024'; '1250410' = 'msfs2020'; '223750' = 'dcs'; '244210' = 'ac'; '1066890' = 'ams2'; '211500' = 'r3e' }
    foreach ($pg in $PerfGames) { if ($route -and $route -match $pg.RouteMatch) { return $pg.Id } }
    $id = Get-GameId $game
    if ($id -match '^steam\.app\.(\d+)$' -and $steam.ContainsKey($Matches[1])) { return $steam[$Matches[1]] }
    return $null
}

$ui.PerfBtn.Add_Click({
    try { Show-Performance (Get-PerfIdForGame (Selected-Game)) } catch { Set-Status "Performance failed: $($_.Exception.Message)" $true }
})
# Keep the guard's scheduled task pointing at this copy of the app, and start it if it should be running
$window.Add_Loaded({ if ($Test) { return }; try { Update-GuardTask; $t = Get-GuardTask; if ($t -and $t.State -ne 'Disabled' -and -not (Test-GuardRunning)) { Start-Guard } } catch { } })

# ---------- Add games window ----------
function Show-AddGames {
    $script:aw = New-DarkWindow 'Add games' 1000 680 @'
  <DockPanel Margin="16">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#B4BCCC" Margin="0,0,0,12"
      Text="Add games to your Pimax Play library, the same way Import in Pimax Play does. Pick .exe files or shortcuts, or scan a folder (a Steam library, a folder of games, or one game's folder). Check the name and the .exe for each game, untick any you don't want, then click Add. Nothing changes in Pimax Play until you apply your changes."/>
    <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoPlus}" x:Name="APick" Content="Add .exe or shortcut..." Margin="0,0,8,0"
              Background="#2F6BFF" BorderBrush="#5B8CFF" FontWeight="SemiBold"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoFolder}" x:Name="AScan" Content="Scan a folder..." Margin="0,0,18,0"/>
      <Button x:Name="AAll" Content="Select all" Margin="0,0,6,0"/>
      <Button x:Name="ANone" Content="Select none" Margin="0,0,6,0"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoClose}" x:Name="AClear" Content="Clear list"/>
    </WrapPanel>
    <TextBlock x:Name="AStatus" DockPanel.Dock="Bottom" Margin="0,10,0,0" Foreground="#4ADE80" TextWrapping="Wrap"/>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <Button x:Name="ACancel" DockPanel.Dock="Right" Content="Cancel" Margin="8,0,0,0"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoCheck}" x:Name="AAdd" DockPanel.Dock="Right" Content="Add games"
              Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold"/>
      <CheckBox x:Name="AImages" IsChecked="True" VerticalAlignment="Center"
                Content="Find a cover image for each game automatically (Steam, or SteamGridDB with a key)"/>
    </DockPanel>
    <Grid>
      <TextBlock x:Name="AEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#4B5263" TextAlignment="Center"
                 Text="No games yet.&#x0a;Click Add .exe or shortcut... or Scan a folder... to start."/>
      <ListBox x:Name="AList"/>
    </Grid>
  </DockPanel>
'@
    $script:aList = $script:aw.FindName('AList'); $script:aStatus = $script:aw.FindName('AStatus'); $script:aAddBtn = $script:aw.FindName('AAdd')
    $script:aEmpty = $script:aw.FindName('AEmpty'); $script:aImages = $script:aw.FindName('AImages')
    $script:aRows = New-Object Collections.ArrayList
    $script:aHave = Get-LibraryRoutes
    $script:addResult = $null
    $script:aSay = { param([string]$m, [bool]$bad = $false) $script:aStatus.Foreground = $(if ($bad) { '#F87171' } else { '#4ADE80' }); $script:aStatus.Text = $m }

    # Marks a row that is already in the library, and keeps the Add button's count up to date
    $script:aCheckRow = {
        param($row)
        $route = [string]$row.Exe.SelectedItem
        $hit = if ($route) { $script:aHave[(Get-RouteKey $route)] } else { $null }
        $row.InLibrary = [bool]$hit
        if ($hit) {
            $row.Note.Text = "Already in your library as $($hit.Name)"; $row.Note.Foreground = '#FBBF24'
            $row.Check.IsChecked = $false; $row.Note.Visibility = 'Visible'
        } else { $row.Note.Text = ''; $row.Note.Visibility = 'Collapsed' }
    }
    $script:aUpdate = {
        $n = @($script:aRows | Where-Object { $_.Check.IsChecked }).Count
        $script:aAddBtn.Content = $(if ($n -eq 1) { 'Add 1 game' } elseif ($n) { "Add $n games" } else { 'Add games' })
        $script:aAddBtn.IsEnabled = ($n -gt 0)
        $script:aEmpty.Visibility = $(if ($script:aRows.Count) { 'Collapsed' } else { 'Visible' })
    }
    $script:aAddRow = {
        param([string]$name, [string]$route, [string[]]$others)
        if ($script:aRows | Where-Object { (Get-RouteKey ([string]$_.Exe.SelectedItem)) -eq (Get-RouteKey $route) }) { return $false }
        $row = [pscustomobject]@{ Check = $null; Name = $null; Exe = $null; Note = $null; InLibrary = $false }
        $cb = New-Object Windows.Controls.CheckBox; $cb.IsChecked = $true; $cb.VerticalAlignment = 'Center'; $cb.Margin = '2,0,10,0'
        $cb.Add_Click({ & $script:aUpdate })
        $nb = New-Object Windows.Controls.TextBox; $nb.Text = $name; $nb.Width = 260; $nb.Margin = '0,0,10,0'; $nb.ToolTip = 'Name shown in Pimax Play'
        $ex = New-Object Windows.Controls.ComboBox; $ex.Margin = '0,0,0,0'
        [void]$ex.Items.Add($route); foreach ($o in @($others)) { if ($o) { [void]$ex.Items.Add($o) } }
        $ex.SelectedIndex = 0; $ex.ToolTip = $(if ($ex.Items.Count -gt 1) { 'The program Pimax starts. Pick another .exe here if this is the wrong one.' } else { 'The program Pimax starts' })
        $ex.Tag = $row
        $ex.Add_SelectionChanged({ & $script:aCheckRow $this.Tag; & $script:aUpdate })
        $note = New-Object Windows.Controls.TextBlock; $note.FontSize = 11.5; $note.Margin = '0,3,0,0'
        $top = New-Object Windows.Controls.DockPanel
        [Windows.Controls.DockPanel]::SetDock($cb, 'Left'); [Windows.Controls.DockPanel]::SetDock($nb, 'Left')
        foreach ($c in $cb, $nb, $ex) { [void]$top.Children.Add($c) }
        $stack = New-Object Windows.Controls.StackPanel
        [void]$stack.Children.Add($top); [void]$stack.Children.Add($note)
        $note.Margin = '298,3,0,0'
        $row.Check = $cb; $row.Name = $nb; $row.Exe = $ex; $row.Note = $note
        $item = New-Object Windows.Controls.ListBoxItem; $item.Content = $stack; $item.Tag = $row; $item.Padding = '8,6'
        [void]$script:aList.Items.Add($item); [void]$script:aRows.Add($row)
        & $script:aCheckRow $row
        return $true
    }

    $script:aw.FindName('APick').Add_Click({
        $dlg = New-Object Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Games (*.exe, *.lnk)|*.exe;*.lnk|All files|*.*'; $dlg.Multiselect = $true; $dlg.DereferenceLinks = $false
        $dlg.Title = 'Pick the game .exe files or shortcuts to add'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $n = 0; foreach ($f in $dlg.FileNames) { if (& $script:aAddRow (Get-GameNameFromPath $f) $f @()) { $n++ } }
        & $script:aUpdate
        & $script:aSay "Added $n file(s) to the list. Check the names, then click Add."
    })
    $script:aw.FindName('AScan').Add_Click({
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pick a folder to scan for games: a Steam library (for example D:\SteamLibrary), a folder of games, or one game''s folder.'
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog() -ne 'OK') { return }
        & $script:aSay "Scanning $($dlg.SelectedPath)..."
        $script:aw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        try {
            $found = @(Find-GameExes $dlg.SelectedPath)
            $n = 0; foreach ($f in $found) { if (& $script:aAddRow $f.Name $f.Route $f.Others) { $n++ } }
            & $script:aUpdate
            $inLib = @($script:aRows | Where-Object { $_.InLibrary }).Count
            & $script:aSay $(if ($found.Count) { "Found $($found.Count) game(s); $n new in this list. Already-imported games are unticked ($inLib). Steam VR games are already in Pimax as SteamVR; add one here only if you want to give it your own image." } else { 'No games found in that folder. Try the game''s own folder, or Add .exe or shortcut....' }) (-not $found.Count)
        } catch { & $script:aSay "Couldn't scan that folder: $($_.Exception.Message)" $true }
    })
    $script:aw.FindName('AAll').Add_Click({ foreach ($r in $script:aRows) { if (-not $r.InLibrary) { $r.Check.IsChecked = $true } }; & $script:aUpdate })
    $script:aw.FindName('ANone').Add_Click({ foreach ($r in $script:aRows) { $r.Check.IsChecked = $false }; & $script:aUpdate })
    $script:aw.FindName('AClear').Add_Click({ $script:aList.Items.Clear(); $script:aRows.Clear(); & $script:aUpdate; & $script:aSay '' })
    $script:aw.FindName('ACancel').Add_Click({ $script:aw.Close() })
    $script:aAddBtn.Add_Click({
        $rows = @($script:aRows | Where-Object { $_.Check.IsChecked })
        if (-not $rows.Count) { & $script:aSay 'Tick at least one game.' $true; return }
        $bad = $rows | Where-Object { -not $_.Name.Text.Trim() } | Select-Object -First 1
        if ($bad) { & $script:aSay 'Every ticked game needs a name.' $true; $bad.Name.Focus(); return }
        $entries = @(foreach ($r in $rows) { [pscustomobject]@{ Name = $r.Name.Text.Trim(); Route = [string]$r.Exe.SelectedItem; Image = $null } })
        $script:aAddBtn.IsEnabled = $false
        try {
            if ($script:aImages.IsChecked) {
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    & $script:aSay "Finding cover images ($($i + 1) of $($entries.Count)): $($entries[$i].Name)..."
                    $script:aw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
                    try { $entries[$i].Image = Find-AutoCover $entries[$i].Name $entries[$i].Route } catch { }
                }
            }
            $r = Add-ImportedGames $entries
            $msg = "$($r.Added.Count) game(s) ready to add"
            $withImg = @($r.Added | Where-Object { $_.HasImage }).Count
            if ($r.Added.Count) { $msg += " ($withImg with a cover image)" }
            $msg += '.'
            if ($r.Skipped.Count) { $msg += " Skipped: $($r.Skipped -join '; ')." }
            if ($r.ImageFailed.Count) { $msg += " Couldn't download an image for: $($r.ImageFailed -join ', ')." }
            if ($r.Added.Count -and ($r.Added.Count - $withImg)) { $msg += ' Pick a game without an image and click Find image to give it one.' }
            if ($r.Added.Count) { $msg += " $WaitingHint" }
            $script:addResult = [pscustomobject]@{ Message = $msg; Bad = (-not $r.Added.Count); FirstId = $(if ($r.Added.Count) { $r.Added[0].Id } else { $null }) }
            $script:aw.Close()
        } catch {
            & $script:aSay "Couldn't add the games: $($_.Exception.Message)" $true
            $script:aAddBtn.IsEnabled = $true
        }
    })
    & $script:aUpdate
    if ($script:Capture -or $Test) { return $script:aw }
    [void]$script:aw.ShowDialog()
}

$ui.AddBtn.Add_Click({
    try { Show-AddGames } catch { Set-Status "Add games failed: $($_.Exception.Message)" $true; return }
    if ($script:addResult) {
        if ($script:addResult.FirstId) { $script:SelectAfterFill = Join-Path $ManifestDir "$($script:addResult.FirstId).json" }
        Fill-List
        Set-Status $script:addResult.Message $script:addResult.Bad
    }
})

# ---------- Edit / remove an imported game ----------
function Show-EditGame($game) {
    $script:ew = New-DarkWindow 'Edit game' 720 290 @'
  <DockPanel Margin="18">
    <TextBlock x:Name="EInfo" DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#B4BCCC" Margin="0,0,0,14"/>
    <TextBlock x:Name="EStatus" DockPanel.Dock="Bottom" Margin="0,10,0,0" Foreground="#F87171" TextWrapping="Wrap"/>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,14,0,0">
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoTrash}" x:Name="ERemove" DockPanel.Dock="Left" Content="Remove from library"
              Background="#3A1518" BorderBrush="#7F1D1D"/>
      <Button x:Name="ECancel" DockPanel.Dock="Right" Content="Cancel" Margin="8,0,0,0"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoCheck}" x:Name="ESave" DockPanel.Dock="Right" Content="Save"
              Background="#16A34A" BorderBrush="#22C55E" FontWeight="SemiBold"/>
      <Border/>
    </DockPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <TextBlock Text="Name" VerticalAlignment="Center"/>
      <TextBox x:Name="EName" Grid.Column="1" Grid.ColumnSpan="2"/>
      <TextBlock Text="Program" Grid.Row="2" VerticalAlignment="Center"/>
      <TextBox x:Name="ERoute" Grid.Row="2" Grid.Column="1"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoFolder}" x:Name="EBrowse" Grid.Row="2" Grid.Column="2" Content="Browse..." Margin="8,0,0,0"/>
    </Grid>
  </DockPanel>
'@
    $script:eGame = $game
    $script:editResult = $null
    $script:ew.FindName('EInfo').Text = "Rename $($game.Name), or point it at a different .exe or shortcut (for example a mod's launcher). Removing it takes it out of Pimax Play only; the game itself isn't touched, and the library entry is kept in the app's backups folder. Changes are applied with Apply & restart Pimax Play."
    $script:eName = $script:ew.FindName('EName'); $script:eRoute = $script:ew.FindName('ERoute'); $script:eStatus = $script:ew.FindName('EStatus')
    $script:eName.Text = $game.Name; $script:eRoute.Text = Get-Route $game
    $script:ew.FindName('ECancel').Add_Click({ $script:ew.Close() })
    $script:ew.FindName('EBrowse').Add_Click({
        $dlg = New-Object Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Games (*.exe, *.lnk)|*.exe;*.lnk|All files|*.*'; $dlg.DereferenceLinks = $false
        try { $d = Split-Path $script:eRoute.Text; if (Test-Path -LiteralPath $d) { $dlg.InitialDirectory = $d } } catch { }
        if ($dlg.ShowDialog() -eq 'OK') { $script:eRoute.Text = $dlg.FileName }
    })
    $script:ew.FindName('ESave').Add_Click({
        $name = $script:eName.Text.Trim(); $route = $script:eRoute.Text.Trim('"', ' ')
        if ($name -eq $script:eGame.Name -and $route -eq (Get-Route $script:eGame)) { $script:ew.Close(); return }
        try {
            Set-ImportedGame $script:eGame $name $route
            $script:editResult = [pscustomobject]@{ Message = $(if ($script:Pending.Count) { "Changes to $name are waiting to be applied. $WaitingHint" } else { "$name is back to how it was." }); Bad = $false; Keep = $script:eGame.File }
            $script:ew.Close()
        } catch { $script:eStatus.Foreground = '#F87171'; $script:eStatus.Text = $_.Exception.Message }
    })
    $script:ew.FindName('ERemove').Add_Click({
        $a = [Windows.MessageBox]::Show("Remove $($script:eGame.Name) from your Pimax Play library?`n`nThe game itself isn't touched, and you can add it again any time with Add games. It's removed when you apply your changes.", 'Remove game', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { return }
        try {
            [void](Remove-ImportedGames @($script:eGame))
            $script:editResult = [pscustomobject]@{ Message = $(if (@($script:Pending | Where-Object { $_.Kind -eq 'remove' -and $_.File -eq $script:eGame.File }).Count) { "$($script:eGame.Name) will be removed when you apply your changes. $WaitingHint" } else { "$($script:eGame.Name) won't be added after all." }); Bad = $false; Keep = $null }
            $script:ew.Close()
        } catch { $script:eStatus.Foreground = '#F87171'; $script:eStatus.Text = "Couldn't remove it: $($_.Exception.Message)" }
    })
    if ($script:Capture -or $Test) { return $script:ew }
    [void]$script:ew.ShowDialog()
}

$ui.EditBtn.Add_Click({
    $g = Selected-Game
    if (-not $g -or $g.Source -ne 'Imported') { Set-Status 'Pick an imported game on the left first.' $true; return }
    try { Show-EditGame $g } catch { Set-Status "Edit game failed: $($_.Exception.Message)" $true; return }
    if ($script:editResult) {
        if ($script:editResult.Keep) { $script:SelectAfterFill = $script:editResult.Keep }
        Fill-List
        if (-not $ui.GameList.SelectedItem) { $ui.GameTitle.Text = 'Pick a game on the left'; $ui.GameInfo.Text = ''; Show-Preview $null; $ui.EditBtn.IsEnabled = $false; $ui.PlayBtn.IsEnabled = $false }
        Set-Status $script:editResult.Message $script:editResult.Bad
    }
})
$ui.EditBtn.IsEnabled = $false

# ---------- Play ----------
function Invoke-PlaySelected {
    $g = Selected-Game
    if (-not $g) { Set-Status 'Pick a game on the left first.' $true; return }
    try { Start-Game $g; Set-Status "Starting $($g.Name)..." }
    catch { Set-Status "Couldn't start $($g.Name): $($_.Exception.Message)" $true }
}
$ui.PlayBtn.Add_Click({ Invoke-PlaySelected })
# Double-clicking a game in the list starts it (not double-clicks on the scrollbar or empty space)
$ui.GameList.Add_MouseDoubleClick({
    if ($_.ChangedButton -ne 'Left') { return }
    $el = $_.OriginalSource
    while ($el -and -not ($el -is [Windows.Controls.ListBoxItem])) {
        if ($el -is [Windows.Controls.Primitives.ScrollBar]) { return }
        $el = if ($el -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
    }
    if ($el) { Invoke-PlaySelected }
})

# ---------- Backup & restore window ----------
function Format-SnapshotLine($s) {
    $when = ([datetime]$s.created).ToString('MMM d, yyyy  h:mm tt')
    $parts = @("$(@($s.images).Count) image(s)", "$(@($s.pinned).Count) pinned", "$(@($s.settings).Count) settings file(s)", "$(@($s.headset | Where-Object { $_ }).Count) headset file(s)")
    "{0}   -   {1}   -   {2}" -f $when, $s.reason, ($parts -join ', ')
}

function Show-Backups($preselect, $lost) {
    $script:bw = New-DarkWindow 'Backup & restore' 900 600 @'
  <DockPanel Margin="14">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#B4BCCC" Margin="0,0,0,10"
      Text="A backup of your library images, library order, game settings and headset settings (eye-tracking calibration, IPD and headset profile, play area) is saved automatically every time you change them here, and when you open the app. If a Pimax update resets them, pick a backup and restore it."/>
    <TextBlock x:Name="BStatus" DockPanel.Dock="Bottom" Margin="0,10,0,0" Foreground="#4ADE80" TextWrapping="Wrap"/>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Button x:Name="BClose" DockPanel.Dock="Right" Content="Close" Margin="8,0,0,0"/>
      <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoUndo}" x:Name="BRestore" DockPanel.Dock="Right" Content="Restore selected" Background="#EA580C" BorderBrush="#FB923C" FontWeight="SemiBold"/>
      <StackPanel Orientation="Horizontal">
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoArchive}" x:Name="BNow" Content="Back up now" Background="#16A34A" BorderBrush="#22C55E"/>
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoFolder}" x:Name="BOpen" Content="Open backup folder" Margin="8,0,0,0"/>
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoTrash}" x:Name="BDelete" Content="Delete selected" Margin="8,0,0,0" Background="#4C1616" BorderBrush="#DC2626"/>
      </StackPanel>
    </DockPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
      <TextBlock Text="Restore:" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <CheckBox x:Name="BImages" Content="Library images" IsChecked="True" Margin="0,0,16,0"/>
      <CheckBox x:Name="BOrder" Content="Library order" IsChecked="True" Margin="0,0,16,0"/>
      <CheckBox x:Name="BSettings" Content="Game settings" IsChecked="True" Margin="0,0,16,0"/>
      <CheckBox x:Name="BHeadset" Content="Headset (eye tracking, IPD, play area)" IsChecked="True"/>
    </StackPanel>
    <ListBox x:Name="BList" SelectionMode="Extended" Background="#161A21" Foreground="#E8EBF2" BorderBrush="#262C38" ToolTip="Ctrl-click or Shift-click to select several backups"/>
  </DockPanel>
'@
    $script:bList = $script:bw.FindName('BList'); $script:bStatus = $script:bw.FindName('BStatus')
    $script:bSay = { param([string]$m, [bool]$bad = $false) $script:bStatus.Foreground = $(if ($bad) { '#F87171' } else { '#4ADE80' }); $script:bStatus.Text = $m }
    $script:bFill = {
        param($selectPath)
        $script:bList.Items.Clear()
        foreach ($s in Get-Snapshots) {
            $it = New-Object Windows.Controls.ListBoxItem
            $it.Content = Format-SnapshotLine $s; $it.Tag = $s; $it.Padding = '6,5'
            [void]$script:bList.Items.Add($it)
            if ($selectPath -and $s.Path -eq $selectPath) { $script:bList.SelectedItem = $it }
        }
        if (-not $script:bList.SelectedItem -and $script:bList.Items.Count) { $script:bList.SelectedIndex = 0 }
        if (-not $script:bList.Items.Count) { & $script:bSay 'No backups yet. Click Back up now to make one.' }
    }
    & $script:bFill $(if ($preselect) { $preselect.Path } else { $null })
    if ($lost) {
        $script:bw.FindName('BImages').IsChecked = ($lost.Images.Count -gt 0)
        $script:bw.FindName('BOrder').IsChecked = [bool]$lost.Pins
        $script:bw.FindName('BSettings').IsChecked = ($lost.Settings.Count -gt 0)
        $script:bw.FindName('BHeadset').IsChecked = (@($lost.Headset).Count -gt 0)
        & $script:bSay 'The backup from before the reset is selected, with just the missing items ticked.'
    }

    $script:bw.FindName('BClose').Add_Click({ $script:bw.Close() })
    $script:bw.FindName('BOpen').Add_Click({ Start-Process explorer.exe $SnapshotDir })
    $script:bw.FindName('BDelete').Add_Click({
        $sel = @($script:bList.SelectedItems | ForEach-Object { $_.Tag })
        if (-not $sel.Count) { & $script:bSay 'Pick the backup(s) to delete first.' $true; return }
        $what = if ($sel.Count -eq 1) { 'the backup from ' + ([datetime]$sel[0].created).ToString('MMM d, h:mm tt') } else { "$($sel.Count) backups" }
        $a = [Windows.MessageBox]::Show("Delete $what?`n`nThis can't be undone.", 'Delete backup', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { return }
        try { $n = Remove-Snapshots @($sel | ForEach-Object { $_.Path }); & $script:bFill $null; & $script:bSay "Deleted $n backup(s)." }
        catch { & $script:bSay "Couldn't delete: $($_.Exception.Message)" $true }
    })
    $script:bw.FindName('BNow').Add_Click({
        try { $d = New-Snapshot 'Manual'; & $script:bFill $d; & $script:bSay 'Backup saved.' }
        catch { & $script:bSay "Couldn't back up: $($_.Exception.Message)" $true }
    })
    $script:bw.FindName('BRestore').Add_Click({
        $it = $script:bList.SelectedItem
        if (-not $it) { & $script:bSay 'Pick a backup first.' $true; return }
        if ($script:bList.SelectedItems.Count -gt 1) { & $script:bSay 'Pick just one backup to restore.' $true; return }
        $img = [bool]$script:bw.FindName('BImages').IsChecked; $ord = [bool]$script:bw.FindName('BOrder').IsChecked; $set = [bool]$script:bw.FindName('BSettings').IsChecked; $hs = [bool]$script:bw.FindName('BHeadset').IsChecked
        if (-not ($img -or $ord -or $set -or $hs)) { & $script:bSay 'Tick at least one thing to restore.' $true; return }
        $what = @($(if ($img) { 'library images' }), $(if ($ord) { 'library order' }), $(if ($set) { 'game settings' }), $(if ($hs) { 'headset settings' })) | Where-Object { $_ }
        $a = [Windows.MessageBox]::Show("Restore $($what -join ', ') from the backup of $(([datetime]$it.Tag.created).ToString('MMM d, h:mm tt'))?`n`nYour current state is backed up first, so you can undo this.$(if ($hs) { "`n`nRestoring headset settings briefly restarts the Pimax headset software - take the headset off first." })", 'Restore backup', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        & $script:bSay 'Restoring - restarting Pimax...'
        $script:bw.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        try {
            $r = Restore-Snapshot $it.Tag $img $ord $set $hs
            $msg = "Restored: $($r.Images) image(s), $($r.Order) pinned game(s) in order, $($r.Settings) settings file(s), $($r.Headset) headset file(s)."
            if ($hs -and -not $r.RuntimeBack) { $msg += ' The Pimax headset software did not restart on its own - restart your PC to finish applying the headset settings.' }
            if ($r.Skipped.Count) { $msg += " Skipped (not in your library now): $($r.Skipped -join ', ')." }
            if (-not $r.ServiceOk) { $msg += ' Could not restart the Pimax service; restart your PC if it does not apply.' }
            & $script:bFill $it.Tag.Path
            & $script:bSay $msg (-not $r.ServiceOk)
            $ui.ResetBar.Visibility = 'Collapsed'
            Fill-List
        } catch { & $script:bSay "Couldn't restore: $($_.Exception.Message)" $true }
    })
    if ($script:Capture -or $Test) { return $script:bw }
    [void]$script:bw.ShowDialog()
}

$ui.BackupBtn.Add_Click({ try { Show-Backups $null $null } catch { Set-Status "Backup & restore failed: $($_.Exception.Message)" $true }; Fill-List })

# On start: if Pimax seems to have reset things since the last backup, offer to restore; otherwise take a backup
function Start-BackupCheck {
    try {
        $last = Get-Snapshots | Where-Object { $_.reason -ne 'Before restore' } | Select-Object -First 1
        if ($last) {
            $cmp = Compare-Snapshot $last
            if ($cmp.Any -and (Get-AppSetting 'dismissedSnapshot') -ne $last.created) {
                $bits = @()
                if ($cmp.Images.Count) { $bits += "$($cmp.Images.Count) library image(s)" }
                if ($cmp.Pins) { $bits += 'your library order' }
                if ($cmp.Settings.Count) { $bits += "$($cmp.Settings.Count) game settings file(s)" }
                if (@($cmp.Headset).Count) { $bits += ((@($cmp.Headset) | Select-Object -Unique) -join ', ').ToLower() }
                $script:ResetSnap = $last; $script:ResetLost = $cmp
                $ui.ResetText.Text = "Pimax seems to have reset some of your changes ($($bits -join ', ')). Restore them from your backup of $(([datetime]$last.created).ToString('MMM d, h:mm tt'))?"
                $ui.ResetBar.Visibility = 'Visible'
                return
            }
        }
        Save-AutoSnapshot
    } catch { }
}
$ui.ResetRestore.Add_Click({ try { Show-Backups $script:ResetSnap $script:ResetLost } catch { Set-Status "Backup & restore failed: $($_.Exception.Message)" $true }; Fill-List })
$ui.ResetDismiss.Add_Click({ if ($script:ResetSnap) { Set-AppSetting 'dismissedSnapshot' $script:ResetSnap.created }; $ui.ResetBar.Visibility = 'Collapsed' })
$window.Add_Loaded({ if ($Test) { return }; $window.Dispatcher.BeginInvoke([action]{ Start-BackupCheck }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null })

# ---------- Tutorial (shown at startup until the user turns it off) ----------
$TutorialSteps = @(
    @{ Icon = 'Logo'; Title = 'Welcome to Pimax Game Manager'
       Body = "Keep your Pimax Play library the way you want it: add and start games, your own tile images, your own order, graphics settings for many games at once, and backups that a Pimax update can't wipe.`n`nThis quick tour takes about a minute." },
    @{ Icon = 'IcoPlay'; Title = 'Play games'; Since = '1.8.0'
       Body = "Pick a game on the left and click Play at the top right, or just double-click it in the list.`n`nGames start the same way Pimax Play starts them: Steam games through Steam, imported and Oculus games from their own .exe. Which runtime a game uses (Pimax OpenXR or SteamVR) is still set in Pimax Play." },
    @{ Icon = 'IcoImage'; Title = 'Custom library images'
       Body = "Pick an imported game on the left, then click Find image to search Steam and SteamGridDB, paste an image link, or Browse for a file. Click Use image to use it.`n`nSteam and Oculus games get their image from the store every time Pimax starts. To give one your own image, add its .exe with Add games." },
    @{ Icon = 'IcoPlus'; Title = 'Add games'
       Body = "Add games... puts games into Pimax Play without using its Import button. Pick .exe files or shortcuts, or scan a folder such as a Steam library, and the app can find a cover image for each one.`n`nEdit / remove... renames an imported game, points it at a different .exe (handy for mods), or takes it out of the library." },
    @{ Icon = 'IcoList'; Title = 'Library order'
       Body = "Library order lets you tick games to pin them and drag them into any order. Pinned games always show first in Pimax Play.`n`nTip: click Pin all, then drag, to control the whole list." },
    @{ Icon = 'IcoSliders'; Title = 'Game settings'
       Body = "Edit Pimax's per-game graphics settings in one place. Tick Custom to give a game its own value; everything else follows Global.`n`nApply to... copies one setting to other games, Copy all settings to... gives them the same full setup, and nothing is written until you click Save all changes." },
    @{ Icon = 'IcoGauge'; Title = 'Performance'; Since = '1.9.0'
       Body = "Some games keep their graphics in their own file and reset it after an update. Performance... locks the settings you want in truck, racing and flight sims (ATS, ETS2, MSFS, DCS, Falcon BMS, iRacing, Assetto Corsa, AMS2, RaceRoom), with a VR starting point to begin from.`n`nIt can also run a game on your CPU's performance cores and pull its desktop window back on screen. The Performance Guard does this in the background from a tray icon." },
    @{ Icon = 'IcoArchive'; Title = 'Backups'
       Body = "A backup is saved automatically whenever you change something here. If a Pimax update resets your images, order, settings or headset setup, an orange bar offers to put them back.`n`nYou can also restore any backup yourself from Backup & restore." },
    @{ Icon = 'IcoPower'; Title = 'Applying changes'
       Body = "New games, edits and images wait in a yellow bar at the top until you click Apply & restart Pimax Play, so you can make lots of changes and restart Pimax once. If you close the app first, it asks whether to apply them.`n`nApplying restarts Pimax Play and its service, so do it when you're not in a game. Library order and Game settings saves apply waiting changes in the same restart." },
    @{ Icon = 'IcoDownload'; Title = 'Updates and help'
       Body = "When a new version is out, a blue bar at the top offers Update now: the app downloads it, installs it and reopens. The bottom-right corner shows whether you're up to date.`n`nReport a problem opens a bug report on GitHub. You can open this tour again any time from Tutorial at the bottom of the window." }
)

# Steps marked Since are shown once after an update, even to people who turned the tour off at startup.
# 'tutorialSeen' is the app version when the tour was last seen; before 1.8.2 it wasn't recorded, so 1.7.3 is assumed.
function Get-NewTutorialSteps([string]$seen = [string](Get-AppSetting 'tutorialSeen')) {
    try { $seenV = [version]$seen } catch { $seenV = [version]'1.7.3' }
    @($TutorialSteps | Where-Object { $_.Since -and [version]$_.Since -gt $seenV -and [version]$_.Since -le [version]$AppVersion })
}

function Show-Tutorial([object[]]$steps = $TutorialSteps, [switch]$WhatsNew) {
    $script:tSteps = @($steps); $script:tWhatsNew = [bool]$WhatsNew
    $script:tw = New-DarkWindow $(if ($WhatsNew) { "What's new in Pimax Game Manager" } else { 'Welcome to Pimax Game Manager' }) 680 470 @'
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Grid Margin="30,28,30,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid Width="120" Height="120" VerticalAlignment="Top" HorizontalAlignment="Left">
        <Ellipse Fill="{StaticResource LogoGrad}" Opacity="0.12"/>
        <Ellipse Stroke="{StaticResource LogoGrad}" StrokeThickness="1.5" Opacity="0.55"/>
        <Image x:Name="TLogo" Source="{StaticResource LogoImage}" Width="82"/>
        <Viewbox x:Name="TIconBox" Width="52" Height="52">
          <Canvas Width="24" Height="24">
            <Path x:Name="TIcon" Stroke="{StaticResource LogoGrad}" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
          </Canvas>
        </Viewbox>
      </Grid>
      <StackPanel Grid.Column="1">
        <TextBlock x:Name="TStep" Foreground="#5B8CFF" FontSize="11" FontWeight="SemiBold"/>
        <TextBlock x:Name="TTitle" FontSize="22" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,4,0,12"/>
        <TextBlock x:Name="TBody" Foreground="#C4CAD6" FontSize="14" TextWrapping="Wrap" LineHeight="21"/>
      </StackPanel>
    </Grid>
    <Border Grid.Row="1" Background="#14171E" BorderBrush="#222733" BorderThickness="0,1,0,0" Padding="20,14">
      <DockPanel>
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoArrowRight}" x:Name="TNext" DockPanel.Dock="Right" Content="Next"
                Background="#2F6BFF" BorderBrush="#5B8CFF" FontWeight="SemiBold" Margin="8,0,0,0" MinWidth="100"/>
        <Button Style="{StaticResource IconBtn}" Tag="{StaticResource IcoArrowLeft}" x:Name="TBack" DockPanel.Dock="Right" Content="Back"/>
        <CheckBox x:Name="THide" Content="Don't show this at startup" VerticalAlignment="Center"/>
        <StackPanel x:Name="TDots" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
  </Grid>
'@
    $script:tw.ResizeMode = 'NoResize'
    $script:tIndex = 0
    $script:tHide = $script:tw.FindName('THide')
    $script:tHide.IsChecked = [bool](Get-AppSetting 'hideTutorial')
    $script:tRender = {
        $w = $script:tw; $s = $script:tSteps[$script:tIndex]; $last = ($script:tIndex -eq $script:tSteps.Count - 1)
        $w.FindName('TStep').Text = $(if ($script:tWhatsNew) { "NEW SINCE YOUR LAST VERSION" + $(if ($script:tSteps.Count -gt 1) { "  -  $($script:tIndex + 1) OF $($script:tSteps.Count)" }) } else { "STEP $($script:tIndex + 1) OF $($script:tSteps.Count)" })
        $w.FindName('TTitle').Text = $s.Title
        $w.FindName('TBody').Text = $s.Body
        $isLogo = ($s.Icon -eq 'Logo')
        $w.FindName('TLogo').Visibility = $(if ($isLogo) { 'Visible' } else { 'Collapsed' })
        $w.FindName('TIconBox').Visibility = $(if ($isLogo) { 'Collapsed' } else { 'Visible' })
        if (-not $isLogo) { $w.FindName('TIcon').Data = $w.FindResource($s.Icon) }
        $w.FindName('TBack').Visibility = $(if ($script:tIndex -gt 0) { 'Visible' } else { 'Hidden' })
        $next = $w.FindName('TNext')
        $next.Content = $(if (-not $last) { 'Next' } elseif ($script:tWhatsNew) { 'Got it' } else { 'Get started' })
        $next.Tag = $w.FindResource($(if ($last) { 'IcoCheck' } else { 'IcoArrowRight' }))
        $dots = $w.FindName('TDots'); $dots.Children.Clear()
        for ($i = 0; $i -lt $script:tSteps.Count -and $script:tSteps.Count -gt 1; $i++) {
            $d = New-Object Windows.Controls.Border
            $d.Height = 7; $d.CornerRadius = '3.5'; $d.Margin = '3,0'
            $d.Width = $(if ($i -eq $script:tIndex) { 20 } else { 7 })
            $d.Background = $(if ($i -eq $script:tIndex) { '#5B8CFF' } else { '#2E3542' })
            [void]$dots.Children.Add($d)
        }
    }
    $script:tGo = {
        param([int]$step)
        $n = $script:tIndex + $step
        if ($n -lt 0) { return }
        if ($n -ge $script:tSteps.Count) { $script:tw.Close(); return }
        $script:tIndex = $n; & $script:tRender
    }
    $script:tw.FindName('TNext').Add_Click({ & $script:tGo 1 })
    $script:tw.FindName('TBack').Add_Click({ & $script:tGo -1 })
    $script:tw.Add_PreviewKeyDown({
        if ($_.Key -eq 'Right') { & $script:tGo 1; $_.Handled = $true }
        elseif ($_.Key -eq 'Left') { & $script:tGo -1; $_.Handled = $true }
        elseif ($_.Key -eq 'Escape') { $script:tw.Close() }
    })
    if ($WhatsNew) { $script:tHide.Content = "Don't show the full tour at startup"; $script:tHide.ToolTip = 'New steps are still shown once after an update. Tutorial at the bottom of the window opens the full tour.' }
    # Remember the "don't show at startup" choice and that this version's tour has been seen (never in test mode)
    $script:tw.Add_Closed({ if (-not $Test) { try { Set-AppSetting 'hideTutorial' ([bool]$script:tHide.IsChecked); Set-AppSetting 'tutorialSeen' $AppVersion } catch { } } })
    & $script:tRender
    if ($script:Capture -or $Test) { return $script:tw }
    [void]$script:tw.ShowDialog()
}

# ---------- Update check ----------
function Get-UpdateInfo($release) {
    $tag = [string]$release.tag_name
    try { $latest = [version]($tag.TrimStart('v', 'V')) } catch { return $null }
    if ($latest -le [version]$AppVersion) { return $null }
    $asset = { param($n) $a = @($release.assets) | Where-Object { $_.name -ieq $n } | Select-Object -First 1
               if ($a) { [pscustomobject]@{ Url = [string]$a.browser_download_url; Size = [long]$a.size; Sha256 = ([string]$a.digest -replace '^sha256:', '') } } }
    [pscustomobject]@{ Version = $latest.ToString(); Url = [string]$release.html_url
                       Setup = (& $asset 'PimaxGameManagerSetup.exe'); Exe = (& $asset 'PimaxGameManager.exe') }
}

# ---------- Self-update ----------
# How this copy is running: 'installed' (by PimaxGameManagerSetup.exe), 'portable' (the plain exe), or 'script' (the .ps1)
# (an installed copy has the installer's unins000.exe / unins000.dat next to it)
function Get-InstallKind([string]$exePath) {
    if (-not $exePath) { $exePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    if ([IO.Path]::GetFileNameWithoutExtension($exePath) -ine 'PimaxGameManager') { return [pscustomobject]@{ Kind = 'script'; Exe = $exePath } }
    $dir = Split-Path $exePath
    if ((Test-Path -LiteralPath (Join-Path $dir 'unins000.exe')) -and (Test-Path -LiteralPath (Join-Path $dir 'unins000.dat'))) { return [pscustomobject]@{ Kind = 'installed'; Exe = $exePath } }
    return [pscustomobject]@{ Kind = 'portable'; Exe = $exePath }
}

# Checks a downloaded file: size, SHA-256 (when GitHub lists one) and the version stamped in the file
function Test-UpdateFile([string]$path, $asset, [string]$version) {
    $f = Get-Item -LiteralPath $path
    if ($asset.Size -and $f.Length -ne $asset.Size) { throw "The download is incomplete ($($f.Length) of $($asset.Size) bytes)." }
    if ($asset.Sha256 -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $asset.Sha256) { throw "The download didn't match GitHub's checksum." }
    $v = [string]$f.VersionInfo.FileVersion
    try { $ok = ([version]$v -eq [version]$version) } catch { $ok = $false }
    if (-not $ok) { throw "The downloaded file is version '$v', not $version." }
}

# Writes the small script that runs after the app closes: waits for it to exit, installs the update
# (silent installer, or swaps the exe and keeps the old one as .old until the new one is in place), then reopens the app.
function New-UpdaterScript([string]$kind, [string]$download, [string]$target, [int]$appPid, [string]$log, [bool]$launch) {
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    @"
`$ErrorActionPreference = 'Stop'
function Log([string]`$m) { Add-Content -LiteralPath $(& $q $log) -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), `$m) }
try {
    Log 'Waiting for Pimax Game Manager to close'
    try { Wait-Process -Id $appPid -Timeout 60 -ErrorAction Stop } catch { }
    Start-Sleep -Milliseconds 800
    if ($(& $q $kind) -eq 'installed') {
        Log 'Running the installer silently'
        `$dirArg = '/DIR="' + (Split-Path $(& $q $target)) + '"'
        `$p = Start-Process -FilePath $(& $q $download) -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CURRENTUSER','/CLOSEAPPLICATIONS',`$dirArg -Wait -PassThru
        Log "Installer finished with code `$(`$p.ExitCode)"
        if (`$p.ExitCode -ne 0) { throw "installer exit code `$(`$p.ExitCode)" }
        Log ("Installed version: " + (Get-Item -LiteralPath $(& $q $target)).VersionInfo.FileVersion)
    } else {
        `$target = $(& $q $target); `$old = `$target + '.old'
        Log "Replacing `$target"
        for (`$i = 0; `$i -lt 20; `$i++) { try { Move-Item -LiteralPath `$target -Destination `$old -Force; break } catch { Start-Sleep -Milliseconds 500; if (`$i -eq 19) { throw } } }
        try { Copy-Item -LiteralPath $(& $q $download) -Destination `$target -Force }
        catch { Move-Item -LiteralPath `$old -Destination `$target -Force; throw }
        Remove-Item -LiteralPath `$old -Force -ErrorAction SilentlyContinue
    }
    Log 'Update installed'
} catch { Log ("Update failed: " + `$_.Exception.Message) }
Remove-Item -LiteralPath $(& $q $download) -Force -ErrorAction SilentlyContinue
if (`$$launch) { Log 'Starting the app'; Start-Process -FilePath $(& $q $target) }
"@
}

# Downloads the update in the background (progress shown in the update bar), then closes the app so the updater can finish
function Start-SelfUpdate {
    $info = $script:UpdateInfo
    if (-not $info) { return }
    $inst = Get-InstallKind
    $asset = if ($inst.Kind -eq 'installed') { $info.Setup } else { $info.Exe }
    if ($inst.Kind -eq 'script' -or -not $asset) { Start-Process $info.Url; return }
    if ($script:Pending.Count) {
        $n = $script:Pending.Count
        $a = [Windows.MessageBox]::Show("You have $n change(s) that haven't been applied to Pimax Play yet. Apply them before updating? Pimax Play will restart.`n`nYes: apply, then update.   No: throw them away and update.   Cancel: don't update now.", 'Update', 'YesNoCancel', 'Question')
        if ($a -eq 'Cancel') { return }
        if ($a -eq 'No') { $script:Pending.Clear(); Fill-List }
        elseif (-not (Invoke-ApplyPending)) { return }
    }
    $dir = Join-Path $env:TEMP 'PimaxGameManager-update'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:UpdDownload = Join-Path $dir ("{0}-{1}" -f $info.Version, [IO.Path]::GetFileName(([uri]$asset.Url).LocalPath))
    Remove-Item -LiteralPath $script:UpdDownload -Force -ErrorAction SilentlyContinue
    $script:UpdKind = $inst; $script:UpdAsset = $asset
    $ui.UpdateBtn.IsEnabled = $false; $ui.UpdateClose.IsEnabled = $false
    $ui.UpdateText.Text = "Downloading version $($info.Version)..."
    $wc = New-Object Net.WebClient
    $wc.Headers.Add('User-Agent', 'pimax-game-manager')
    $script:UpdDl = $wc.DownloadFileTaskAsync([uri]$asset.Url, $script:UpdDownload)
    $script:UpdTimer = New-Object Windows.Threading.DispatcherTimer
    $script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:UpdTimer.Add_Tick({
        $v = $script:UpdateInfo.Version
        if (-not $script:UpdDl.IsCompleted) {
            $got = 0; try { $got = (Get-Item -LiteralPath $script:UpdDownload -ErrorAction Stop).Length } catch { }
            if ($script:UpdAsset.Size) { $ui.UpdateText.Text = "Downloading version $v...  {0:0}%" -f [Math]::Min(99, 100 * $got / $script:UpdAsset.Size) }
            return
        }
        $script:UpdTimer.Stop()
        $fail = {
            param($m)
            $ui.UpdateText.Text = "Couldn't update: $m  Click Update now to try again, or download it from GitHub."
            $ui.UpdateBtn.IsEnabled = $true; $ui.UpdateClose.IsEnabled = $true
            Remove-Item -LiteralPath $script:UpdDownload -Force -ErrorAction SilentlyContinue
        }
        if ($script:UpdDl.Status -ne 'RanToCompletion') { & $fail "the download failed ($($script:UpdDl.Exception.InnerException.Message))."; return }
        try { Test-UpdateFile $script:UpdDownload $script:UpdAsset $v } catch { & $fail $_.Exception.Message; return }
        try {
            $log = Join-Path $DataDir 'update.log'
            $helper = Join-Path (Split-Path $script:UpdDownload) 'apply-update.ps1'
            $text = New-UpdaterScript $script:UpdKind.Kind $script:UpdDownload $script:UpdKind.Exe $PID $log $true
            [IO.File]::WriteAllText($helper, $text, (New-Object Text.UTF8Encoding($true)))
            try { Stop-Guard } catch { }    # the guard runs from the same exe; it is started again when the app reopens
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helper`""
            Set-AppSetting 'updatedFrom' $AppVersion
            $ui.UpdateText.Text = "Installing version $v - the app will reopen in a moment..."
            $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
            Start-Sleep -Milliseconds 600
            $window.Close()
        } catch { & $fail $_.Exception.Message }
    })
    $script:UpdTimer.Start()
}

function Set-VersionLabel([string]$state) {
    $l = $ui.VersionLabel
    $l.TextDecorations = $null
    switch ($state) {
        'checking'  { $l.Text = "v$AppVersion  -  Checking for updates..."; $l.Foreground = '#7A8397' }
        'current'   { $l.Text = "v$AppVersion  -  Up to date " + [char]0x2713; $l.Foreground = '#4ADE80' }
        'available' { $l.Text = "v$AppVersion  -  Update available"; $l.Foreground = '#5B8CFF'; $l.TextDecorations = [Windows.TextDecorations]::Underline }
        default     { $l.Text = "v$AppVersion  -  Couldn't check for updates"; $l.Foreground = '#7A8397' }
    }
    $script:VersionState = $state
}

function Show-UpdateNotice($release) {
    $info = Get-UpdateInfo $release
    if (-not $info) { Set-VersionLabel 'current'; return }
    $script:UpdateUrl = $info.Url; $script:UpdateInfo = $info
    $auto = ((Get-InstallKind).Kind -ne 'script') -and $info.Setup -and $info.Exe
    $ui.UpdateBtn.Content = if ($auto) { 'Update now' } else { 'Download' }
    $ui.UpdateBtn.ToolTip = if ($auto) { 'Download and install the update, then reopen the app' } else { 'Open the release page on GitHub' }
    $ui.UpdateText.Text = "Version $($info.Version) of Pimax Game Manager is available (you have $AppVersion)." + $(if ($auto) { ' Update now installs it and reopens the app.' } else { '' })
    $ui.UpdateBar.Visibility = 'Visible'
    Set-VersionLabel 'available'
}

# Download in the background; a timer on the UI thread picks up the result
function Start-UpdateCheck {
    if ($script:VersionState -eq 'checking') { return }
    Set-VersionLabel 'checking'
    try {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', 'pimax-game-manager')
        $wc.Encoding = [Text.Encoding]::UTF8
        $script:UpdateTask = $wc.DownloadStringTaskAsync([uri]$RepoApi)
        $script:UpdateStarted = Get-Date
        $script:UpdatePoll = New-Object Windows.Threading.DispatcherTimer
        $script:UpdatePoll.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:UpdatePoll.Add_Tick({
            if (-not $script:UpdateTask.IsCompleted) {
                if (((Get-Date) - $script:UpdateStarted).TotalSeconds -gt 30) { $script:UpdatePoll.Stop(); Set-VersionLabel 'failed' }
                return
            }
            $script:UpdatePoll.Stop()
            if ($script:UpdateTask.Status -ne 'RanToCompletion') { Set-VersionLabel 'failed'; return }
            try { Show-UpdateNotice ($script:UpdateTask.Result | ConvertFrom-Json) } catch { Set-VersionLabel 'failed' }
        })
        $script:UpdatePoll.Start()
    } catch { Set-VersionLabel 'failed' }
}

# Bug report form on GitHub, with the app version filled in
function Get-ReportUrl { 'https://github.com/SFXShannon/pimax-game-manager/issues/new?template=bug_report.yml&version=' + [uri]::EscapeDataString($AppVersion) }
$ui.ReportLink.Add_MouseLeftButtonUp({ try { Start-Process (Get-ReportUrl) } catch { Set-Status "Couldn't open the browser. Report problems at github.com/SFXShannon/pimax-game-manager/issues" $true } })

$ui.UpdateBtn.Add_Click({ try { Start-SelfUpdate } catch { $ui.UpdateBtn.IsEnabled = $true; $ui.UpdateClose.IsEnabled = $true; Set-Status "Couldn't update: $($_.Exception.Message)" $true } })
$ui.UpdateClose.Add_Click({ $ui.UpdateBar.Visibility = 'Collapsed' })
$ui.VersionLabel.Add_MouseLeftButtonUp({
    if ($script:VersionState -eq 'available' -and $script:UpdateInfo) { $ui.UpdateBar.Visibility = 'Visible' }
    else { Start-UpdateCheck }
})
# After an update: say so once
$window.Add_Loaded({
    if ($Test) { return }
    $from = [string](Get-AppSetting 'updatedFrom')
    if (-not $from) { return }
    Set-AppSetting 'updatedFrom' ''
    if ($from -ne $AppVersion) { Set-Status "Updated from $from to $AppVersion." }
    else { Set-Status "The update didn't install - details are in $(Join-Path $DataDir 'update.log')" $true }
})
$window.Add_Loaded({ if (-not $Test) { Start-UpdateCheck } })
# Full tour at startup unless turned off; if it is off, steps added since the last version seen are shown once
$window.Add_Loaded({ if ($Test) { return }; $window.Dispatcher.BeginInvoke([action]{ try {
    if (-not (Get-AppSetting 'hideTutorial')) { Show-Tutorial }
    else { $new = Get-NewTutorialSteps; if ($new.Count) { Show-Tutorial $new -WhatsNew } else { Set-AppSetting 'tutorialSeen' $AppVersion } }
} catch { } }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null })
$ui.TutorialLink.Add_MouseLeftButtonUp({ try { Show-Tutorial } catch { Set-Status "Tutorial failed: $($_.Exception.Message)" $true } })

$ui.RestartBtn.Add_Click({ [void](Invoke-ApplyPending) })
$ui.RefreshBtn.Add_Click({ Fill-List; Set-Status 'Library list refreshed.' })

Fill-List
if ($ui.GameList.Items.Count -eq 0) { Set-Status "No games found in $ManifestDir - is Pimax Play installed?" $true }

if ($Test) {
    if ($env:PGM_SHOTS) {
        # Screenshot mode: render each window off-screen to PNG files (nothing is changed)
        $shotDir = $env:PGM_SHOTS; New-Item -ItemType Directory -Force $shotDir | Out-Null
        function Save-Shot($w, [string]$name) {
            if (-not $w.IsVisible) { $w.WindowStartupLocation = 'Manual'; $w.Left = -20000; $w.Top = -20000; $w.ShowActivated = $false; $w.ShowInTaskbar = $false; $w.Show() }
            for ($i = 0; $i -lt 4; $i++) { $w.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ContextIdle); Start-Sleep -Milliseconds 150 }
            $root = [Windows.Media.VisualTreeHelper]::GetChild($w, 0)
            $wd = [Math]::Ceiling($root.ActualWidth); $ht = [Math]::Ceiling($root.ActualHeight)
            $dv = New-Object Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
            $rect = New-Object Windows.Rect(0, 0, $wd, $ht)
            $dc.DrawRectangle($w.Background, $null, $rect); $dc.DrawRectangle((New-Object Windows.Media.VisualBrush($root)), $null, $rect); $dc.Close()
            $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$wd, [int]$ht, 96, 96, [Windows.Media.PixelFormats]::Pbgra32); $rtb.Render($dv)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [IO.File]::Create((Join-Path $shotDir "$name.png")); try { $enc.Save($fs) } finally { $fs.Close() }
            "  shot: $name ($wd x $ht)"
        }
        $pick = $ui.GameList.Items | Where-Object { $_.Tag.Source -eq 'Imported' -and $_.Tag.Icon } | Select-Object -First 1
        if ($pick) { $ui.GameList.SelectedItem = $pick }
        Save-Shot $window 'main'
        if ($pick -and $env:PGM_SCAN) {
            # Waiting changes are only held in memory, so nothing is written
            $s = @(Find-GameExes $env:PGM_SCAN | Where-Object { -not (Get-LibraryRoutes)[(Get-RouteKey $_.Route)] } | Select-Object -First 2)
            [void](Add-ImportedGames @($s | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Route = $_.Route } }))
            $rn = Get-PimaxGames | Where-Object { $_.Source -eq 'Imported' -and $_.File -ne $pick.Tag.File } | Select-Object -First 1
            if ($rn) { Set-ImportedGame $rn ($rn.Name + ' VR') (Get-Route $rn) }
            Fill-List; Set-Status "$($s[0].Name) is ready to add. $WaitingHint"
            Save-Shot $window 'main-pending'
            $wg = Get-PimaxGames -WithPending | Where-Object { $_.Pending -eq 'new' } | Select-Object -First 1
            if ($wg) { $script:FinderTerm = $null; $fw = Show-Finder $wg; "  finder on waiting game $($wg.Name): $(@($fw.FindName('Results').Children).Count) images"; Save-Shot $fw 'finder-pending'; $fw.Close() }
            $script:Pending.Clear(); Fill-List
        }
        $tw = Show-Tutorial
        for ($ti = 0; $ti -lt $TutorialSteps.Count; $ti++) { $script:tIndex = $ti; & $script:tRender; Save-Shot $tw "tutorial-$($ti + 1)" }
        $tw.Close()
        $tw = Show-Tutorial (Get-NewTutorialSteps '1.7.3') -WhatsNew; Save-Shot $tw 'whats-new'
        $tw.Close()
        [void](Show-Order); Save-Shot $script:ow 'order'; $script:ow.Close()
        $sid = if ($pick) { Get-GameId $pick.Tag } else { 'global' }
        $sw = Show-GameSettings $sid; Save-Shot $sw 'settings'; $sw.Close()
        $pfw = Show-Performance 'ats'; Save-Shot $pfw 'performance'; $pfw.Close()
        $bw = Show-Backups $null $null; Save-Shot $bw 'backups'; $bw.Close()
        if ($pick) { $script:FinderTerm = 'Crysis'; $fw = Show-Finder $pick.Tag; Save-Shot $fw 'finder'; $fw.Close() }
        $aw = Show-AddGames
        if ($env:PGM_SCAN) { foreach ($f in @(Find-GameExes $env:PGM_SCAN) | Select-Object -First 9) { [void](& $script:aAddRow $f.Name $f.Route $f.Others) } }
        & $script:aUpdate; & $script:aSay "Found $($script:aRows.Count) game(s). Check the names, then click Add."
        Save-Shot $aw 'add-games'; $aw.Close()
        if ($pick) { $ew = Show-EditGame $pick.Tag; Save-Shot $ew 'edit-game'; $ew.Close() }
        $window.Close()
        return
    }
    "TEST OK: window built, $($ui.GameList.Items.Count) games listed"
    foreach ($item in $ui.GameList.Items) {
        $g = $item.Tag
        "  {0,-45} Steam app: {1}" -f $g.Name, (Resolve-SteamAppId $g)
    }
    "--- Play (launch targets only; nothing is started):"
    foreach ($item in $ui.GameList.Items) {
        $g = $item.Tag; $t = Get-LaunchTarget $g
        $ok = if (-not $t) { 'NO ROUTE' } elseif ($t.Kind -eq 'link' -or (Test-Path -LiteralPath $t.Path)) { 'ok' } else { 'FILE MISSING' }
        "  {0,-40} {1,-8} {2,-12} {3}" -f $g.Name, $(if ($t) { $t.Kind } else { '-' }), $ok, $(if ($t) { $t.Path })
    }
    $ui.GameList.SelectedIndex = 0
    "  Play button enabled for '$($ui.GameTitle.Text)': $($ui.PlayBtn.IsEnabled)"
    "--- Tour: new steps shown once to people who turned it off:"
    foreach ($seen in '', '1.7.3', '1.8.0', $AppVersion, 'junk') { "  last seen '$seen' -> new steps: " + ((Get-NewTutorialSteps $seen | ForEach-Object Title) -join ', ') }
    $tw = Show-Tutorial (Get-NewTutorialSteps '1.7.3') -WhatsNew
    "  what's new window: '$($tw.Title)' / '$($tw.FindName('TStep').Text)' / button '$($tw.FindName('TNext').Content)' / checkbox '$($tw.FindName('THide').Content)'"
    $tw.Close()
    "--- Update check (app version $AppVersion):"
    try {
        $rel = Invoke-RestMethod -UseBasicParsing -Uri $RepoApi -Headers @{ 'User-Agent' = 'pimax-game-manager' }
        "  latest on GitHub: $($rel.tag_name)"
        "  newer than this app: " + [bool](Get-UpdateInfo $rel)
        $fake = [pscustomobject]@{ tag_name = 'v9.9.9'; html_url = 'https://example.test/r' }
        Show-UpdateNotice $fake
        "  simulated v9.9.9 -> bar visible: $($ui.UpdateBar.Visibility); text: $($ui.UpdateText.Text)"
        "  simulated v1.0.0 -> notice: " + [bool](Get-UpdateInfo ([pscustomobject]@{ tag_name = 'v1.0.0' }))
    } catch { "  check failed: $($_.Exception.Message)" }
    "--- Report link: '$($ui.ReportLink.Text)' -> $(Get-ReportUrl)"
    "--- Performance (nothing is written):"
    "  P-cores: $(Get-PCoreText (Get-PCoreMask))   guard task: $(if (Get-GuardTask) { (Get-GuardTask).State } else { 'none' })   guard running: $(Test-GuardRunning)"
    foreach ($pg in $PerfGames) { "  {0,-36} {1}" -f $pg.Name, $(if (Get-PerfConfigPath $pg) { (Get-PerfConfigPath $pg) } else { '(not found)' }) }
    foreach ($it in $ui.GameList.Items) { $pid2 = Get-PerfIdForGame $it.Tag; if ($pid2) { "  library entry '$($it.Tag.Name)' -> $pid2" } }
    $pfw = Show-Performance 'ats'
    "  window: '$($script:pfTitle.Text)', $($script:pfRows.Count) settings, locked: $(@($script:pfRows | Where-Object { $_.Check.IsChecked }).Count), guard box: $($script:pfGuardOn.IsChecked)"
    $script:pfTargets.SelectedItem = ($script:pfTargets.Items | Where-Object { $_.Tag -eq 'msfs2024' })
    "  switched to: '$($script:pfTitle.Text)', $($script:pfRows.Count) settings"
    $pfw.FindName('Recommend').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    "  Recommended for VR: $($script:pfStatus.Text)"
    $pfw.Close()
    "--- Game settings (on a temporary copy of AppConfig; Pimax is not touched):"
    $realCfg = $AppConfigDir
    $AppConfigDir = Join-Path $env:TEMP ('pgm-test-' + [guid]::NewGuid().ToString('N'))
    Copy-Item $realCfg $AppConfigDir -Recurse
    $BackupDir = Join-Path $AppConfigDir '_backups'; New-Item -ItemType Directory $BackupDir | Out-Null
    $SnapshotDir = Join-Path $AppConfigDir '_snapshots'; New-Item -ItemType Directory $SnapshotDir | Out-Null
    $script:restarts = 0
    function Invoke-WhilePimaxStopped([scriptblock]$action, [switch]$Full) { $script:restarts++; if ($Full) { $script:fullRestarts++ }; Write-PendingChanges; & $action; $script:RuntimeBack = $true; return $true }
    foreach ($f in Get-ChildItem $AppConfigDir -Filter *.json) {
        $before = [IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n"
        Write-GameSettings $f.BaseName (Read-GameSettings $f.BaseName)
        $after = [IO.File]::ReadAllText($f.FullName)
        "  round-trip $($f.Name): " + $(if ($before.TrimEnd() -eq $after.TrimEnd()) { 'identical' } else { "DIFFERENT`n$before`n---`n$after" })
    }
    $sw = Show-GameSettings 'local.08db6433'
    $click = { param($b) $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    $rowOf = { param($k) $script:gsRows | Where-Object { $_.Def.Key -eq $k } }
    $pick = { param($row, $val) $row.Control.SelectedItem = ($row.Control.Items | Where-Object { $_.Tag -eq $val }) }
    $goTo = { param($id) $script:targets.SelectedItem = ($script:targets.Items | Where-Object { $_.Tag -eq $id }) }
    $fileOf = { param($id) $p = Get-SettingsPath $id; if (Test-Path $p) { ((Get-Content $p -Raw).Trim() -replace '\s+', ' ') } else { '(no file)' } }
    "  opened: $($script:gsTitle.Text)"
    # 1. Crysis: quality High (auto render 1.0) + center rendering Quality
    & $pick (& $rowOf 'piplay_display_quality_level') 2
    $c = & $rowOf 'runtime_foveated_rendering_level'; $c.Check.IsChecked = $true; $c.Control.IsEnabled = $true; & $pick $c 2
    # 2. switch to Pistol Whip, turn on Smart Smoothing custom
    & $goTo 'steam.app.1079800'
    "  switched to: $($script:gsTitle.Text); save button: $($script:gsSaveBtn.Content)"
    $a = & $rowOf 'runtime_dbg_asw_enable'; $a.Check.IsChecked = $true; $a.Control.IsEnabled = $true; & $pick $a 1
    # 3. apply Pistol Whip's Smart Smoothing to Beat Saber, copy all to The Forest
    function Select-Games { return @('steam.app.620980') }
    & $click $a.Apply
    function Select-Games { return @('steam.app.242760') }
    & $click $sw.FindName('CopyAll')
    "  queued: $($script:gsSaveBtn.Content); restarts so far: $script:restarts; files unchanged so far: " + ((& $fileOf 'steam.app.620980') -eq '(no file)')
    # 4. back to Crysis: edits kept?
    & $goTo 'local.08db6433'
    "  back on Crysis - quality: $((& $rowOf 'piplay_display_quality_level').Control.SelectedItem.Content), render: $((& $rowOf 'runtime_pixels_per_display_pixel_rate').Control.Text), center: $((& $rowOf 'runtime_foveated_rendering_level').Control.SelectedItem.Content)"
    "  list marks: " + (($script:targets.Items | Where-Object { $_.Content -match 'unsaved' } | ForEach-Object { $_.Content.Trim() }) -join ' | ')
    # 5. save all at once
    & $click $script:gsSaveBtn
    "  status: " + $script:gsStatus.Text + "   restarts: $script:restarts"
    "  CrysisVR:    " + (& $fileOf 'local.08db6433')
    "  Pistol Whip: " + (& $fileOf 'steam.app.1079800')
    "  Beat Saber:  " + (& $fileOf 'steam.app.620980')
    "  The Forest:  " + (& $fileOf 'steam.app.242760')
    "  save button after: $($script:gsSaveBtn.Content); unsaved marks left: " + @($script:targets.Items | Where-Object { $_.Content -match 'unsaved' }).Count
    # 6. undo + invalid value handling
    $rr = & $rowOf 'runtime_pixels_per_display_pixel_rate'; $rr.Control.Text = '5'
    & $click $script:gsSaveBtn
    "  invalid value: " + $script:gsStatus.Text
    & $click $sw.FindName('Revert')
    "  after undo, render: $($rr.Control.Text); dirty: $script:gsDirty"
    # 7. reset a game to global
    & $click $script:gsResetBtn
    "  reset button: $($script:gsResetBtn.Content); custom rows ticked now: " + @($script:gsRows | Where-Object { $_.Check.IsChecked }).Count + "; status: $($script:gsStatus.Text)"
    & $click $script:gsSaveBtn
    "  after save, CrysisVR file: " + (& $fileOf 'local.08db6433') + "; restarts: $script:restarts"
    & $goTo 'global'
    "  on Global the button reads: $($script:gsResetBtn.Content)"
    "  backups: " + ((Get-ChildItem (Join-Path $BackupDir 'settings') -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')
    "  real AppConfig untouched: " + (-not (Test-Path (Join-Path $realCfg 'steam.app.620980.json')))
    Remove-Item $AppConfigDir -Recurse -Force
    "--- Backup & restore (on temporary copies; Pimax is not touched):"
    $keepManifest = $ManifestDir; $keepClient = $ClientConfig; $keepCovers = $CoverDir
    $bt = Join-Path $env:TEMP ('pgm-bk-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $bt | Out-Null
    Copy-Item $ManifestDir (Join-Path $bt 'manifest') -Recurse; $ManifestDir = Join-Path $bt 'manifest'
    Copy-Item $realCfg (Join-Path $bt 'AppConfig') -Recurse; $AppConfigDir = Join-Path $bt 'AppConfig'
    Copy-Item $ClientConfig (Join-Path $bt 'config.json'); $ClientConfig = Join-Path $bt 'config.json'
    if (Test-Path $LegacyBackupDir) { Copy-Item $LegacyBackupDir (Join-Path $bt 'legacy') -Recurse }; $LegacyBackupDir = Join-Path $bt 'legacy'
    $CoverDir = Join-Path $bt 'covers'; $BackupDir = Join-Path $bt 'backups'; $SnapshotDir = Join-Path $bt 'snapshots'
    foreach ($d in $CoverDir, $BackupDir, $SnapshotDir) { New-Item -ItemType Directory $d -Force | Out-Null }
    $HeadsetLocalDir = Join-Path $bt 'hs-local'; $HeadsetProgramDir = Join-Path $bt 'hs-programdata'
    New-Item -ItemType Directory $HeadsetLocalDir, $HeadsetProgramDir -Force | Out-Null
    Copy-Item (Join-Path $env:LOCALAPPDATA 'Pimax\runtime\profile.json'), (Join-Path $env:LOCALAPPDATA 'Pimax\runtime\*.bin') $HeadsetLocalDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $env:ProgramData 'Pimax\runtime\*.vrchap') $HeadsetProgramDir -ErrorAction SilentlyContinue
    "  headset files found: " + ((Get-HeadsetFiles | ForEach-Object { "$($_.Name) [$($_.Kind)]" }) -join '; ')
    # give the copy a pinned order to protect
    [IO.File]::WriteAllText($ClientConfig, (Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) @('local.66be7fbb', 'local.384c724b', 'steam.app.1079800')), $Utf8NoBom)
    $d1 = New-Snapshot 'Manual'
    $snap = Get-Snapshots | Select-Object -First 1
    "  backup made: " + (Format-SnapshotLine $snap)
    "  custom images in backup: " + (($snap.images | ForEach-Object { $_.name }) -join ', ')
    "  second automatic backup with no changes skipped: " + ($null -eq (New-Snapshot 'Automatic' -IfChanged))
    # simulate a Pimax update wiping things
    $cm = Join-Path $ManifestDir 'local.08db6433.json'; $j = Get-Content $cm -Raw | ConvertFrom-Json; $j.icon = ''; [IO.File]::WriteAllText($cm, ($j | ConvertTo-Json -Compress), $Utf8NoBom)
    [IO.File]::WriteAllText($ClientConfig, (Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) @()), $Utf8NoBom)
    Remove-Item (Join-Path $AppConfigDir 'steam.app.1079800.json')
    Remove-Item (Join-Path $HeadsetLocalDir '*.bin'), (Join-Path $HeadsetProgramDir '*.vrchap')
    $ipdOf = { ([regex]::Match([IO.File]::ReadAllText((Join-Path $HeadsetLocalDir 'profile.json')), '"ipd" : ([0-9.]+)')).Groups[1].Value }
    $ipdBefore = & $ipdOf
    $pjText = [IO.File]::ReadAllText((Join-Path $HeadsetLocalDir 'profile.json')) -replace '"ipd" : [0-9.]+', '"ipd" : 0.07'; [IO.File]::WriteAllText((Join-Path $HeadsetLocalDir 'profile.json'), $pjText)
    $old = Join-Path $ManifestDir 'local.384c724b.json'; $j = Get-Content $old -Raw | ConvertFrom-Json; $j.id = 'local.deadbeef'; $j.icon = ''
    [IO.File]::WriteAllText((Join-Path $ManifestDir 'local.deadbeef.json'), ($j | ConvertTo-Json -Compress), $Utf8NoBom); Remove-Item $old
    "  simulated wipe: Crysis image cleared, order emptied, Pistol Whip settings deleted, Flight Sim re-imported as local.deadbeef"
    $cmp = Compare-Snapshot $snap
    "  detected lost -> images: $($cmp.Images -join ', '); order: $($cmp.Pins); settings: $($cmp.Settings -join ', '); headset: $(($cmp.Headset | Select-Object -Unique) -join ', ')"
    $script:restarts = 0
    $script:fullRestarts = 0
    $r = Restore-Snapshot $snap $true $true $true $true
    "  headset restore: $($r.Headset) file(s), full runtime restart used: $($script:fullRestarts -eq 1); eye calibration back: $(@(Get-ChildItem $HeadsetLocalDir -Filter *.bin).Count -gt 0); play area back: $(@(Get-ChildItem $HeadsetProgramDir -Filter *.vrchap).Count -gt 0); IPD back to $ipdBefore : $((& $ipdOf) -eq $ipdBefore)"
    "  restore report: images $($r.Images), pinned $($r.Order), settings $($r.Settings), skipped: $($r.Skipped -join ', '); Pimax restarts: $script:restarts"
    $ci = (Get-Content $cm -Raw | ConvertFrom-Json).icon
    "  Crysis icon now: $([IO.Path]::GetFileName($ci)) (file exists: $(Test-Path $ci))"
    $fi = (Get-Content (Join-Path $ManifestDir 'local.deadbeef.json') -Raw | ConvertFrom-Json).icon
    "  Flight Sim (new id) icon now: $([IO.Path]::GetFileName($fi)) (file exists: $(Test-Path $fi))"
    "  pinned now: " + ((Get-PinnedIds) -join ', ')
    "  Pistol Whip settings back: " + (Test-Path (Join-Path $AppConfigDir 'steam.app.1079800.json'))
    "  after restore, anything still lost: " + (Compare-Snapshot $snap).Any
    "  backups now: " + ((Get-Snapshots | ForEach-Object reason) -join ', ')
    $bwin = Show-Backups $null $null
    "  Backup window lists: $($script:bList.Items.Count) backup(s)"
    $script:bList.SelectAll(); $script:bw.FindName('BRestore').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    "  restore with 2 selected says: $($script:bStatus.Text)"
    $manual = Get-Snapshots | Where-Object { $_.reason -eq 'Manual' } | Select-Object -First 1
    "  deleted: " + (Remove-Snapshots @($manual.Path)) + "; backups left: " + ((Get-Snapshots | ForEach-Object reason) -join ', ')
    try { Remove-Snapshots @($AppConfigDir) | Out-Null; "  SAFETY FAILED: deleted a non-backup folder" } catch { "  refuses non-backup folder: " + $_.Exception.Message.Substring(0, 22) + " ... (still exists: $(Test-Path $AppConfigDir))" }
    "--- Add / edit / remove games and waiting changes (on the temporary copies):"
    $gdir = Join-Path $bt 'games'
    foreach ($f in 'Cool Game\CoolGame.exe', 'Cool Game\unins000.exe', 'Cool Game\CrashReporter.exe', 'Cool Game\Tools\CoolGameEditor.exe', 'Other Thing\bin\win64\Launcher.exe', 'Other Thing\bin\win64\OtherThing.exe', 'Tiny\tiny.exe') {
        $p = Join-Path $gdir $f; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; Copy-Item "$env:WINDIR\System32\notepad.exe" $p
    }
    [IO.File]::WriteAllBytes((Join-Path $gdir 'Tiny\tiny.exe'), (New-Object byte[] 1000))
    $found = @(Find-GameExes $gdir)
    "  scan found: " + (($found | ForEach-Object { "$($_.Name) -> $($_.Route.Substring($gdir.Length + 1))" }) -join '; ')
    $hashDir = { (Get-ChildItem $ManifestDir -Filter *.json | Sort-Object Name | ForEach-Object { $_.Name + (Get-FileHash $_.FullName -Algorithm MD5).Hash }) -join ',' }
    $diskBefore = & $hashDir; $pinsBefore = (Get-PinnedIds) -join ','
    $script:restarts = 0; $script:Pending.Clear()
    $aw = Show-AddGames
    foreach ($f in $found) { [void](& $script:aAddRow $f.Name $f.Route $f.Others) }
    $crysisRoute = Get-Route (Get-PimaxGames | Where-Object { $_.Name -eq 'CrysisVR' } | Select-Object -First 1)
    [void](& $script:aAddRow 'Crysis again' $crysisRoute @())
    "  duplicate of the same file in the list refused: " + (-not (& $script:aAddRow 'Cool again' $found[0].Route @()))
    & $script:aUpdate
    "  rows: $($script:aRows.Count); already-in-library row unticked: $(-not ($script:aRows | Where-Object { $_.InLibrary }).Check.IsChecked); note: $(($script:aRows | Where-Object { $_.InLibrary }).Note.Text); button: $($script:aAddBtn.Content)"
    $script:aImages.IsChecked = $false
    $script:aRows[0].Name.Text = 'Cool Game VR'
    $script:aAddBtn.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    "  result: $($script:addResult.Message)"
    "  queued, not written: restarts $script:restarts; Pimax files unchanged: $((& $hashDir) -eq $diskBefore); waiting: $($script:Pending.Count)"
    $view = Get-PimaxGames -WithPending
    $cool = $view | Where-Object { $_.Name -eq 'Cool Game VR' }
    "  shown in the list as: $($cool.Source) / $($cool.Pending); id format ok: $((Get-GameId $cool) -match '^local\.[0-9a-f]{8}$')"
    $fa = try { $x = Find-Art $cool $cool.Name $true; "ok, $(@($x.Items).Count) images" } catch { "FAILED: $($_.Exception.Message)" }; "  Find image on a waiting game: $fa"
    $sa = try { (Resolve-SteamAppId ([pscustomobject]@{ File = (Join-Path $ManifestDir 'local.nothere.json'); Route = $crysisRoute })) } catch { "FAILED: $($_.Exception.Message)" }; "  Steam lookup for a waiting game in a Steam library: $sa"
    $r2 = Add-ImportedGames @([pscustomobject]@{ Name = 'Again'; Route = (Get-Route $cool); Image = $null }, [pscustomobject]@{ Name = 'Missing'; Route = 'C:\nope\x.exe'; Image = $null })
    "  adding a waiting game again: added $($r2.Added.Count); skipped: $($r2.Skipped -join '; ')"
    $img = Get-ChildItem $keepCovers -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($img) {
        [void](Add-ImportedGames @([pscustomobject]@{ Name = 'Tiny'; Route = (Join-Path $gdir 'Tiny\tiny.exe'); Image = $img.FullName }))
        $tiny = Get-PimaxGames -WithPending | Where-Object { $_.Name -eq 'Tiny' }
        "  with image: icon copied into covers: $($tiny.Icon.StartsWith($CoverDir) -and (Test-Path $tiny.Icon))"
    }
    # Edit a game that is still waiting to be added: folds into the add
    $ew = Show-EditGame $cool
    $script:eName.Text = 'Cool Game (mod)'; $script:eRoute.Text = (Join-Path $gdir 'Cool Game\Tools\CoolGameEditor.exe')
    $script:ew.FindName('ESave').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    $ew.Close()
    $cool2 = Get-PimaxGames -WithPending | Where-Object { $_.File -eq $cool.File }
    "  edited waiting game: $($cool2.Name) -> $(Split-Path (Get-Route $cool2) -Leaf); still one change for it: $(@($script:Pending | Where-Object { $_.File -eq $cool.File }).Count -eq 1); message: $($script:editResult.Message.Substring(0, 40))..."
    try { Set-ImportedGame $cool2 'X' $crysisRoute; '  EDIT SAFETY FAILED' } catch { "  refuses an exe already in the library: $($_.Exception.Message)" }
    try { Set-ImportedGame ($view | Where-Object Source -ne 'Imported' | Select-Object -First 1) 'X' $crysisRoute; '  EDIT SAFETY FAILED' } catch { "  refuses Steam games: $($_.Exception.Message.Substring(0, 40))..." }
    # Remove a game that is still waiting to be added: it just drops out
    $other = Get-PimaxGames -WithPending | Where-Object { $_.Name -eq 'Other Thing' }
    [void](Remove-ImportedGames @($other))
    "  removing a waiting game drops it: $(-not (Get-PimaxGames -WithPending | Where-Object { $_.Name -eq 'Other Thing' }))"
    # Existing games: new image, rename (and rename back = no change), remove a pinned one
    $crysis = Get-PimaxGames | Where-Object { $_.Name -eq 'CrysisVR' }
    $origFile = Get-OrigBackupPath $crysis
    $crysisOrigIcon = if ($origFile) { [string](([IO.File]::ReadAllText($origFile)) | ConvertFrom-Json).icon } else { [string]$crysis.Icon }
    $newIcon = Save-Cover $crysis $img.FullName
    $iracing = Get-PimaxGames | Where-Object { $_.Name -eq 'iRacingUI' }
    Set-ImportedGame $iracing 'iRacing' (Get-Route $iracing)
    $n1 = $script:Pending.Count; Set-ImportedGame $iracing 'iRacingUI' (Get-Route $iracing); $n2 = $script:Pending.Count
    "  rename and rename back: waiting $n1 -> $n2"
    Set-ImportedGame $iracing 'iRacing' (Get-Route $iracing)
    $ats = Get-PimaxGames | Where-Object { $_.Name -eq 'amtrucks' }
    $atsId = Get-GameId $ats
    [IO.File]::WriteAllText($ClientConfig, (Set-PinnedIdsInText ([IO.File]::ReadAllText($ClientConfig)) (@(Get-PinnedIds) + $atsId)), $Utf8NoBom)
    [void](Remove-ImportedGames @($ats, ($view | Where-Object Source -ne 'Imported' | Select-Object -First 1)))
    $v2 = Get-PimaxGames -WithPending
    "  list preview: Crysis icon is the new one: $(($v2 | Where-Object { $_.File -eq $crysis.File }).Icon -eq $newIcon); iRacing renamed: $([bool]($v2 | Where-Object { $_.Name -eq 'iRacing' })); amtrucks hidden: $(-not ($v2 | Where-Object { $_.File -eq $ats.File })); Steam game not removable: $([bool]($v2 | Where-Object Source -ne 'Imported'))"
    "  Pimax files still unchanged: $((& $hashDir) -eq $diskBefore); restarts: $script:restarts"
    Fill-List
    "  bar: visible $($ui.PendingBar.Visibility -eq 'Visible'); '$($ui.PendingText.Text)'"
    "  list badges: " + (@($ui.GameList.Items | Where-Object { $_.Tag.Pending } | ForEach-Object { "$($_.Tag.Name)=$($_.Tag.Pending)" }) -join ', ')
    # Library order shows the waiting games and won't re-pin the one being removed
    [void](Show-Order)
    "  order window lists waiting games: $([bool]($script:lb.Items | Where-Object { $_.Tag.Game.Name -eq 'Cool Game (mod)' })); removed game not kept as unknown pin: $($script:unknownPins -notcontains $atsId)"
    $script:ow.Close()
    # Apply everything in one restart
    $ok = Invoke-ApplyPending
    "  applied: $ok; restarts: $script:restarts; waiting now: $($script:Pending.Count); bar hidden: $($ui.PendingBar.Visibility -eq 'Collapsed'); status: $($ui.Status.Text)"
    $newFiles = @(Get-ChildItem $ManifestDir -Filter *.json | Where-Object { ([IO.File]::ReadAllText($_.FullName)) -match 'Cool Game|Tiny' })
    foreach ($f in $newFiles) { $b = [IO.File]::ReadAllBytes($f.FullName); "  $($f.Name) (BOM: $($b[0] -eq 0xEF)): " + [IO.File]::ReadAllText($f.FullName).Replace($gdir, '<games>').Replace($CoverDir, '<covers>') }
    $cj = [IO.File]::ReadAllText($crysis.File) | ConvertFrom-Json
    "  Crysis icon written: $($cj.icon -eq $newIcon); original kept for Restore: $([bool](Get-OrigBackupPath $crysis))"
    "  iRacing renamed on disk: $((([IO.File]::ReadAllText($iracing.File)) | ConvertFrom-Json).name); old entry copied: $(@(Get-ChildItem (Join-Path $BackupDir 'edited-games')).Count)"
    "  amtrucks removed: $(-not (Test-Path $ats.File)); kept in backups: $(@(Get-ChildItem (Join-Path $BackupDir 'removed-games')).Count -eq 1); unpinned: $((Get-PinnedIds) -notcontains $atsId); other pins kept: $(@(Get-PinnedIds).Count)"
    # Restore original is queued too, and puts back the old icon when applied
    Restore-Cover (Get-PimaxGames | Where-Object { $_.File -eq $crysis.File })
    "  restore queued: $($script:Pending.Count) ($(Get-PendingLabel $script:Pending[0]))"
    [void](Invoke-ApplyPending)
    "  back to the original icon: $([string]((([IO.File]::ReadAllText($crysis.File)) | ConvertFrom-Json).icon) -eq $crysisOrigIcon); .orig cleared: $(-not (Get-OrigBackupPath $crysis))"
    # Image waiting on a game with no custom image, then Restore original: just cancels it
    $tg = Get-PimaxGames | Where-Object { $_.Name -eq 'Tiny' }
    [void](Save-Cover $tg $img.FullName); $c1 = $script:Pending.Count
    Restore-Cover $tg; "  undoing a waiting image on a game with no custom image before: waiting $c1 -> $($script:Pending.Count)"
    # Any other save that restarts Pimax applies waiting changes too (game settings, order, restore use Invoke-WhilePimaxStopped)
    [void](Add-ImportedGames @([pscustomobject]@{ Name = 'Late'; Route = (Join-Path $gdir 'Other Thing\bin\win64\Launcher.exe') }))
    $r0 = $script:restarts
    [void](Invoke-WhilePimaxStopped { })
    "  applied by another save: waiting $($script:Pending.Count); written: $([bool](Get-PimaxGames | Where-Object { $_.Name -eq 'Late' })); extra restarts: $($script:restarts - $r0)"
    $aw.Close()
    $ManifestDir = $keepManifest; $ClientConfig = $keepClient
    Remove-Item $bt -Recurse -Force
    "--- Self-update (temporary folder):"
    $fake = [pscustomobject]@{ tag_name = 'v99.1.0'; html_url = 'https://example/rel'; assets = @(
        [pscustomobject]@{ name = 'PimaxGameManager.exe'; size = 10; digest = 'sha256:ABC'; browser_download_url = 'https://example/PimaxGameManager.exe' },
        [pscustomobject]@{ name = 'PimaxGameManagerSetup.exe'; size = 20; digest = $null; browser_download_url = 'https://example/PimaxGameManagerSetup.exe' }) }
    $ui2 = Get-UpdateInfo $fake
    "  newer release parsed: $($ui2.Version); exe $($ui2.Exe.Size) bytes sha $($ui2.Exe.Sha256); setup $($ui2.Setup.Size) bytes; older ignored: $($null -eq (Get-UpdateInfo ([pscustomobject]@{ tag_name = 'v1.0.0' })))"
    $instDir = "$env:LOCALAPPDATA\Programs\Pimax Game Manager"
    "  kind: script=$((Get-InstallKind 'C:\x\powershell.exe').Kind); temp exe=$((Get-InstallKind 'C:\Temp\PimaxGameManager.exe').Kind); install folder=$((Get-InstallKind (Join-Path $instDir 'PimaxGameManager.exe')).Kind)"
    $ut = Join-Path $env:TEMP ('pgm-upd-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $ut | Out-Null
    $newExe = Join-Path $PSScriptRoot 'PimaxGameManager.exe'
    $newSize = (Get-Item $newExe).Length; $exeVer = (Get-Item $newExe).VersionInfo.FileVersion; $newHash = (Get-FileHash $newExe -Algorithm SHA256).Hash
    $dl = Join-Path $ut 'download.exe'; Copy-Item $newExe $dl
    $check = { param($a, $v) try { Test-UpdateFile $dl $a $v; 'ok' } catch { $_.Exception.Message } }
    "  file check good: " + (& $check ([pscustomobject]@{ Size = $newSize; Sha256 = $newHash }) $exeVer)
    "  wrong size: " + (& $check ([pscustomobject]@{ Size = 5; Sha256 = '' }) $exeVer)
    "  wrong hash: " + (& $check ([pscustomobject]@{ Size = $newSize; Sha256 = 'AB' }) $exeVer)
    "  wrong version: " + (& $check ([pscustomobject]@{ Size = $newSize; Sha256 = '' }) '9.9.9')
    # Portable swap: an "old" exe, a dummy app process to wait for, then run the real updater script
    $target = Join-Path $ut 'PimaxGameManager.exe'
    $oldSrc = Join-Path $instDir 'PimaxGameManager.exe'
    if (Test-Path $oldSrc) { Copy-Item $oldSrc $target } else { [IO.File]::WriteAllText($target, 'old') }
    $oldVer = (Get-Item $target).VersionInfo.FileVersion
    $dummy = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 3' -PassThru
    $ulog = Join-Path $ut 'update.log'; $helper = Join-Path $ut 'apply-update.ps1'
    [IO.File]::WriteAllText($helper, (New-UpdaterScript 'portable' $dl $target $dummy.Id $ulog $false), (New-Object Text.UTF8Encoding($true)))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $hp = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$helper`"" -PassThru; $hp.WaitForExit(90000) | Out-Null
    "  portable update: $oldVer -> $((Get-Item $target).VersionInfo.FileVersion) after $([int]$sw.Elapsed.TotalSeconds)s (waited for the app: $($sw.Elapsed.TotalSeconds -ge 2.5)); .old left: $(Test-Path ($target + '.old')); download cleaned up: $(-not (Test-Path $dl))"
    "  log: " + ((Get-Content $ulog | ForEach-Object { $_.Substring(21) }) -join ' | ')
    # Swap that can't complete (target locked) must leave the old exe in place
    Copy-Item $newExe $dl; $lockT = Join-Path $ut 'Locked\PimaxGameManager.exe'; New-Item -ItemType Directory (Split-Path $lockT) | Out-Null; Copy-Item $target $lockT
    $fs = [IO.File]::Open($lockT, 'Open', 'Read', 'None')
    [IO.File]::WriteAllText($helper, (New-UpdaterScript 'portable' $dl $lockT 999999 $ulog $false), (New-Object Text.UTF8Encoding($true)))
    $hp = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$helper`"" -PassThru; $hp.WaitForExit(90000) | Out-Null
    $fs.Close()
    "  locked exe: still there: $(Test-Path $lockT); last log: $((Get-Content $ulog | Select-Object -Last 1).Substring(21))"
    Remove-Item $ut -Recurse -Force
    "--- Library order window (not shown):"
    Show-Order | ForEach-Object { "  $_" }
    "--- Pin list write test (in memory only):"
    $cfg = [IO.File]::ReadAllText($ClientConfig)
    $ids = @(Get-PimaxGames | ForEach-Object { Get-GameId $_ } | Sort-Object)
    $out = Set-PinnedIdsInText $cfg $ids
    $strip = { param($t) [regex]::Replace($t, '"pinToTopGameArray"\s*:\s*\[[^\]]*\]', 'X') }
    "  rest of settings unchanged: " + ((& $strip $cfg) -eq (& $strip $out))
    "  pinned after write: " + (Get-PinnedIds $out).Count + " of " + $ids.Count
    $noKey = [regex]::Replace($cfg, ',\s*"pinToTopGameArray"\s*:\s*\[[^\]]*\]', '')
    $out2 = Set-PinnedIdsInText $noKey @('a','b')
    "  insert when missing: " + ((Get-PinnedIds $out2) -join ',') + "  tail: " + ($out2.Substring($out2.Length - 60) -replace "`n", '\n' -replace "`t", '\t')
    return
}
[void]$window.ShowDialog()
