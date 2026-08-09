-- HD Grass + LGPE Wind Flowers Combined v1.0.0
-- Combines the user's working HD Grass 3.4.0 build with the working
-- LGPE Flower Replacer 4.1.0 build in one Gen1Recomp mod.
-- Grass installs first; Flowers composes on top of the same live Voxel3D chain.

-- HD Grass + LGPE Flowers Combined v1.0.0 - Grass installer
--
-- Companion mod for DRAMATIC_SHAPE or DRAMALESS_SHAPE. This does not register a competing world
-- renderer. It replaces the live ChunkMesher.grass() answer used by the voxel
-- scene with a lightweight proxy that owns spatially chunked copies of the
-- uploaded OBJ.
--
-- Performance changes versus V3.0:
--   * indexed OBJ geometry: 146 reusable vertices instead of 318 expanded
--     vertices per tuft (same 106 source triangles / same model silhouette)
--   * grass is divided into 64x64-world-pixel chunks
--   * chunk meshes are built lazily only when they become visible
--   * off-screen chunks are culled before Voxel3D.draw, so their vertices never
--     enter the expensive voxel/fog/shadow shader
--   * old / Dramaless builds animate only visible chunks, in-place, at a
--     fixed 60 Hz real-time cadence instead of rebuilding one enormous table
--   * legacy sway precomputes phase sin/cos, avoiding a trig call per vertex
--   * unused chunk meshes are released after a short idle period
--   * custom texture is attached once when a chunk is created, not reset every
--     frame
--
-- Replacement target:
--   Dramatic Shape's upright blocky/voxel tall-grass clumps ONLY.
-- The voxel terrain / grass-coloured floor below them is left alone.

local function installGrass(mod)
  ---------------------------------------------------------------- dependency

  -- The original Dramatic Shape publishes its live module namespace through
  -- exports.lib. Dramaless Shape intentionally uses a different mod id and
  -- currently does not publish that bridge, so we recover its *live* module
  -- tables from the already-registered st_voxel pipeline closure. This is
  -- important: loading fresh copies of Dramaless' lib/*.lua files would patch
  -- duplicate tables that the running scene never calls.
  local dep = mod.find("DRAMALESS_SHAPE") or mod.find("DRAMATIC_SHAPE")
  assert(dep,
    "Grass OBJ Replacer V3.2 needs DRAMALESS_SHAPE or DRAMATIC_SHAPE enabled")

  local targetId = dep.id
  local ChunkMesher, Structures, Voxel3D
  local bridgeMode

  local function isChunkMesher(t)
    return type(t) == "table"
      and type(t.grass) == "function"
      and type(t.request) == "function"
      and type(t.pump) == "function"
      and type(t.invalidate) == "function"
  end

  local function isVoxel3D(t)
    return type(t) == "table"
      and type(t.draw) == "function"
      and type(t.newMesh) == "function"
      and type(t.project) == "function"
      and type(t.seams) == "function"
  end

  local function isStructures(t)
    return type(t) == "table"
      and type(t.forMap) == "function"
      and type(t.buildGrass) == "function"
  end

  local function findUpvalueTable(fn, predicate, depth, seen)
    if type(fn) ~= "function" or not debug or not debug.getupvalue then return nil end
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    depth = depth or 0

    local i = 1
    while true do
      local name, value = debug.getupvalue(fn, i)
      if name == nil then break end
      if type(value) == "table" and predicate(value) then return value end
      if depth > 0 and type(value) == "function" then
        local hit = findUpvalueTable(value, predicate, depth - 1, seen)
        if hit then return hit end
      end
      i = i + 1
    end
    return nil
  end

  local direct = dep.exports and dep.exports.lib
  if type(direct) == "table" and type(direct.require) == "function" then
    ChunkMesher = assert(direct.require("ChunkMesher"), "missing ChunkMesher")
    Structures = assert(direct.require("Structures"), "missing Structures")
    Voxel3D = assert(direct.require("Voxel3D"), "missing Voxel3D")
    bridgeMode = "exports.lib"
  else
    -- Dramaless Shape 1.6.x registers `st_voxel`. Keep `voxel` as a fallback
    -- for older/experimental forks that retained the upstream key.
    local pipe = mod.content.render_pipelines:get("st_voxel")
              or mod.content.render_pipelines:get("voxel")
    assert(type(pipe) == "table",
      "DRAMALESS_SHAPE voxel pipeline was not registered before this addon")
    assert(debug and type(debug.getupvalue) == "function",
      "DRAMALESS_SHAPE compatibility needs Lua debug.getupvalue")

    local seeds = { pipe.invalidate, pipe.drawWorld, pipe.update, pipe.available }
    for _, fn in ipairs(seeds) do
      if not ChunkMesher then
        ChunkMesher = findUpvalueTable(fn, isChunkMesher, 3)
      end
      if not Voxel3D then
        Voxel3D = findUpvalueTable(fn, isVoxel3D, 3)
      end
    end

    assert(isChunkMesher(ChunkMesher),
      "could not locate Dramaless Shape's live ChunkMesher from st_voxel")
    assert(isVoxel3D(Voxel3D),
      "could not locate Dramaless Shape's live Voxel3D from st_voxel")

    -- geometry() closes over runGeometry(), which closes over the exact
    -- Structures table used by the live mesher. If a future fork reshuffles
    -- that closure, this is optional: the safe 4-tufts-per-grass-cell locator
    -- below remains available.
    Structures = findUpvalueTable(ChunkMesher.geometry, isStructures, 4)
              or findUpvalueTable(ChunkMesher.build, isStructures, 4)
              or findUpvalueTable(ChunkMesher.get, isStructures, 5)
    bridgeMode = Structures and "pipeline-upvalues+native-structures"
                            or "pipeline-upvalues+map-fallback"
  end

  assert(isChunkMesher(ChunkMesher), "ChunkMesher.grass is unavailable")
  assert(isVoxel3D(Voxel3D), "Voxel3D draw/mesh API is unavailable")

  --------------------------------------------------------------- parameters

  -- One Dramatic Shape tuft occupies one 8x8 world-pixel tile.
  local TARGET_HEIGHT = 8.0
  local RANDOM_YAW_DEGREES = 5.0

  -- Spatial batching. 64px = 8x8 native tuft positions per dense chunk.
  -- This keeps draw calls low while making camera culling worthwhile.
  local CHUNK_WORLD = 64
  local CULL_MARGIN_PIXELS = 72

  -- Chunks not seen for this many proxy draws release their GPU mesh. Their
  -- tiny centre list stays cached, so walking back only rebuilds that chunk.
  local EVICT_AFTER_DRAWS = 360
  local EVICT_SCAN_PERIOD = 45

  -- Only used by legacy Dramatic Shape versions that predate GPU grassWind.
  local LEGACY_SWAY_PIXELS = 0.75
  local GRASS_SWAY_SPEED = 6.0
  local LEGACY_SWAY_SPEED = GRASS_SWAY_SPEED
  local LEGACY_ANIM_HZ = 60
  local LEGACY_ANIM_STEP = 1 / LEGACY_ANIM_HZ

  ---------------------------------------------------------------- OBJ parser

  local function parseIndex(token, count)
    local n = tonumber(token)
    if not n then return nil end
    if n < 0 then return count + n + 1 end
    return n
  end

  -- Parse the OBJ into an indexed base mesh. V3.0 expanded every triangle to
  -- three standalone vertices. The source actually has 146 unique vertex/UV
  -- combinations for 106 triangles, so keeping an index map cuts per-tuft
  -- vertex storage and vertex-shader work by more than half without changing
  -- a single triangle.
  local function parseObjIndexed()
    local text = assert(mod:read("assets/sht_grass.obj"),
      "missing assets/sht_grass.obj")

    local positions, uvs, triangles = {}, {}, {}
    local material = "mat1"
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

    for line in text:gmatch("[^\r\n]+") do
      local x, y, z = line:match(
        "^v%s+([%+%-%.%deE]+)%s+([%+%-%.%deE]+)%s+([%+%-%.%deE]+)")
      if x then
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        positions[#positions + 1] = { x, y, z }
        minX, minY, minZ = math.min(minX, x), math.min(minY, y), math.min(minZ, z)
        maxX, maxY, maxZ = math.max(maxX, x), math.max(maxY, y), math.max(maxZ, z)
      else
        local u, v = line:match(
          "^vt%s+([%+%-%.%deE]+)%s+([%+%-%.%deE]+)")
        if u then
          uvs[#uvs + 1] = { tonumber(u), tonumber(v) }
        else
          local m = line:match("^usemtl%s+(%S+)")
          if m then
            material = m
          elseif line:match("^f%s+") then
            local refs = {}
            for ref in line:gmatch("%S+") do
              if ref ~= "f" then
                local vi, ti = ref:match("^([^/]+)/([^/]*)")
                if not vi then vi = ref:match("^([^/]+)") end
                refs[#refs + 1] = { vi = vi, ti = ti }
              end
            end
            for i = 2, #refs - 1 do
              triangles[#triangles + 1] = {
                material = material,
                refs = { refs[1], refs[i], refs[i + 1] },
              }
            end
          end
        end
      end
    end

    assert(#positions > 0 and #triangles > 0,
      "grass OBJ contains no usable geometry")

    local centerX = (minX + maxX) * 0.5
    local centerZ = (minZ + maxZ) * 0.5
    local sourceHeight = math.max(0.0001, maxY - minY)
    local scale = TARGET_HEIGHT / sourceHeight

    local verts, indexMap, byKey = {}, {}, {}

    for _, tri in ipairs(triangles) do
      for _, ref in ipairs(tri.refs) do
        local vi = parseIndex(ref.vi, #positions)
        local ti = ref.ti and ref.ti ~= "" and parseIndex(ref.ti, #uvs) or nil
        local key = tostring(tri.material) .. ":" .. tostring(vi) .. ":" .. tostring(ti or 0)
        local idx = byKey[key]
        if not idx then
          local p = positions[vi]
          assert(p, "grass OBJ face references missing vertex")
          local t = (ti and uvs[ti]) or { 0, 0 }

          -- grass_a / grass_b are packed side by side into grass_atlas.png.
          local u = t[1] or 0
          local v = 1 - (t[2] or 0)
          if tri.material == "mat2" then
            u = 0.5 + u * 0.5
          else
            u = u * 0.5
          end

          idx = #verts + 1
          byKey[key] = idx
          verts[idx] = {
            x = (p[1] - centerX) * scale,
            y = (p[2] - minY) * scale,
            z = (p[3] - centerZ) * scale,
            u = u,
            v = v,
          }
        end
        indexMap[#indexMap + 1] = idx
      end
    end

    return verts, indexMap, {
      triangles = #triangles,
      sourcePositions = #positions,
      uniqueVertices = #verts,
      expandedVertices = #triangles * 3,
      width = (maxX - minX) * scale,
      height = (maxY - minY) * scale,
      depth = (maxZ - minZ) * scale,
    }
  end

  local baseVerts, baseMap, stats = parseObjIndexed()

  -------------------------------------------------------- native tuft locator

  local function addCenter(out, seen, x, z, y)
    if type(x) ~= "number" or type(z) ~= "number" then return end
    local key = ("%.3f:%.3f"):format(x, z)
    local prev = seen[key]
    if prev then
      if type(y) == "number" and y < prev.y then prev.y = y end
      return
    end
    local rec = { x = x, z = z, y = type(y) == "number" and y or 0 }
    seen[key] = rec
    out[#out + 1] = rec
  end

  local function centersFromNativeQuads(map)
    if not (Structures and type(Structures.forMap) == "function") then return {} end
    local ok, S = pcall(Structures.forMap, map)
    if not ok or type(S) ~= "table" or type(S.grassQuads) ~= "table" then
      return {}
    end

    local seen, out = {}, {}
    for _, q in ipairs(S.grassQuads) do
      if type(q) == "table" and not q.leaf and not q.firefly then
        local minX, minY, minZ = math.huge, math.huge, math.huge
        local have = false
        for i = 1, 4 do
          local c = q[i]
          if type(c) == "table" and type(c[1]) == "number"
              and type(c[2]) == "number" and type(c[3]) == "number" then
            have = true
            minX = math.min(minX, c[1])
            minY = math.min(minY, c[2])
            minZ = math.min(minZ, c[3])
          end
        end

        if have then
          if type(q.cx) == "number" and type(q.cz) == "number" then
            -- Newer Dramatic Shape exposes the exact tuft centre directly.
            addCenter(out, seen, q.cx, q.cz, minY == math.huge and 0 or minY)
          else
            -- 1.1.x does not carry q.cx/q.cz, but every grass quad is stamped
            -- from one 8x8 tile. The quad's minimum x/z therefore identifies
            -- that native tile exactly; use its 4px centre instead of the V3
            -- fallback that blindly manufactured four tufts per grass cell.
            local tx = math.floor((minX + 0.001) / 8)
            local tz = math.floor((minZ + 0.001) / 8)
            addCenter(out, seen, tx * 8 + 4, tz * 8 + 4,
                      minY == math.huge and 0 or minY)
          end
        end
      end
    end
    return out
  end

  local function centersFromMapFallback(map)
    local out = {}
    if not (map and type(map.isGrassCell) == "function"
        and map.widthCells and map.heightCells) then return out end

    for cy = 0, map.heightCells - 1 do
      for cx = 0, map.widthCells - 1 do
        if map:isGrassCell(cx, cy) then
          local x, z = cx * 16, cy * 16
          out[#out + 1] = { x = x + 4,  z = z + 4,  y = 0 }
          out[#out + 1] = { x = x + 12, z = z + 4,  y = 0 }
          out[#out + 1] = { x = x + 4,  z = z + 12, y = 0 }
          out[#out + 1] = { x = x + 12, z = z + 12, y = 0 }
        end
      end
    end
    return out
  end

  local function tuftCenters(map)
    local out = centersFromNativeQuads(map)
    if #out > 0 then return out, "native-quads" end
    return centersFromMapFallback(map), "map-fallback"
  end

  ------------------------------------------------------------- GPU resources

  local modernGrass = type(Voxel3D.newGrassMesh) == "function"
                      and type(Voxel3D.grassWind) == "function"

  -- The upstream modern voxel renderer supplies its wind speed through
  -- Voxel3D.GRASS_WIND_SPEED. Override that public module value so the exact
  -- same faster sway rate is used on GPU-wind builds as on the legacy CPU
  -- fallback below. 6 rad/s is just under one full sine cycle per second.
  if modernGrass and type(Voxel3D.GRASS_WIND_SPEED) == "number" then
    Voxel3D.GRASS_WIND_SPEED = GRASS_SWAY_SPEED
  end

  local customTexture = nil
  local mapProxies = {}
  local proxyMarker = {}

  local function texture()
    if customTexture then return customTexture end
    customTexture = mod.assets:image("assets/grass_atlas.png")
    if customTexture and customTexture.setFilter then
      customTexture:setFilter("nearest", "nearest")
    end
    return customTexture
  end

  local function hash01(a, b, salt)
    local n = math.sin(a * 127.1 + b * 311.7 + salt * 74.7) * 43758.5453
    return n - math.floor(n)
  end

  local function releaseObject(o)
    if o and o.release then pcall(o.release, o) end
  end

  local function releaseChunk(ch)
    releaseObject(ch.mesh)
    ch.mesh = nil
    ch.bases = nil
    ch.animVerts = nil
    ch.lastAnimStep = nil
    ch.vertexCount = nil
  end

  local function releaseProxy(proxy)
    if not proxy then return end
    for _, ch in ipairs(proxy.chunks or {}) do releaseChunk(ch) end
  end

  local function clearMap(mapId)
    if mapId then
      local proxy = mapProxies[mapId]
      if proxy then releaseProxy(proxy) end
      mapProxies[mapId] = nil
      return
    end
    for _, proxy in pairs(mapProxies) do releaseProxy(proxy) end
    mapProxies = {}
  end

  -------------------------------------------------------------- chunk layout

  local function groupChunks(centers)
    local byKey, chunks = {}, {}
    for _, center in ipairs(centers) do
      local gx = math.floor(center.x / CHUNK_WORLD)
      local gz = math.floor(center.z / CHUNK_WORLD)
      local key = gx .. ":" .. gz
      local ch = byKey[key]
      if not ch then
        ch = {
          gx = gx, gz = gz, centers = {},
          minX = math.huge, maxX = -math.huge,
          minY = math.huge, maxY = -math.huge,
          minZ = math.huge, maxZ = -math.huge,
          mesh = nil, lastSeen = -math.huge,
        }
        byKey[key] = ch
        chunks[#chunks + 1] = ch
      end
      ch.centers[#ch.centers + 1] = center
      ch.minX = math.min(ch.minX, center.x - stats.width * 0.55)
      ch.maxX = math.max(ch.maxX, center.x + stats.width * 0.55)
      ch.minY = math.min(ch.minY, center.y)
      ch.maxY = math.max(ch.maxY, center.y + TARGET_HEIGHT)
      ch.minZ = math.min(ch.minZ, center.z - stats.depth * 0.55)
      ch.maxZ = math.max(ch.maxZ, center.z + stats.depth * 0.55)
    end

    -- Stable order makes diagnostics and cache behaviour deterministic.
    table.sort(chunks, function(a, b)
      if a.gz ~= b.gz then return a.gz < b.gz end
      return a.gx < b.gx
    end)
    return chunks
  end

  local function makeProxy(map)
    local centers, source = tuftCenters(map)
    local proxy = {
      _marker = proxyMarker,
      map = map,
      mapId = map.id,
      source = source,
      count = #centers,
      chunks = groupChunks(centers),
      drawCounter = 0,
      builtChunks = 0,
      builtVertices = 0,
    }
    return proxy
  end

  ----------------------------------------------------------- indexed builders

  local function tuftTransform(center)
    local maxYaw = math.rad(RANDOM_YAW_DEGREES)
    local yaw = (hash01(center.x, center.z, 9.0) * 2 - 1) * maxYaw
    return math.cos(yaw), math.sin(yaw), center.x * 0.050 + center.z * 0.031
  end

  local function appendTuftModern(verts, indexMap, center)
    local c, s, phase = tuftTransform(center)
    local offset = #verts

    for _, v in ipairs(baseVerts) do
      local wx = center.x + v.x * c - v.z * s
      local wz = center.z + v.x * s + v.z * c
      verts[#verts + 1] = {
        wx, center.y + v.y, wz,
        v.u, v.v,
        1.0,
        phase, center.x, center.z, 0.0,
      }
    end
    for _, idx in ipairs(baseMap) do
      indexMap[#indexMap + 1] = offset + idx
    end
  end

  local function appendTuftLegacy(verts, indexMap, bases, center)
    local c, s, phase = tuftTransform(center)
    local offset = #verts

    for _, v in ipairs(baseVerts) do
      local wx = center.x + v.x * c - v.z * s
      local wz = center.z + v.x * s + v.z * c
      local row = { wx, center.y + v.y, wz, v.u, v.v, 1.0 }
      verts[#verts + 1] = row
      local worldY = center.y + v.y
      local h = math.max(0, math.min(1, (worldY - center.y) / TARGET_HEIGHT))
      local phaseAngle = phase + worldY * 0.13
      bases[#bases + 1] = {
        x = wx, y = worldY, z = wz,
        bend = h * h,
        phaseSin = math.sin(phaseAngle),
        phaseCos = math.cos(phaseAngle),
      }
    end
    for _, idx in ipairs(baseMap) do
      indexMap[#indexMap + 1] = offset + idx
    end
  end

  local function buildChunk(proxy, ch)
    if ch.mesh then return ch.mesh end
    if #ch.centers == 0 then return nil end

    local verts, indexMap, bases = {}, {}, {}
    if modernGrass then
      for _, center in ipairs(ch.centers) do
        appendTuftModern(verts, indexMap, center)
      end
    else
      for _, center in ipairs(ch.centers) do
        appendTuftLegacy(verts, indexMap, bases, center)
      end
    end

    local mesh
    if modernGrass then
      mesh = Voxel3D.newGrassMesh(verts, indexMap)
    else
      mesh = Voxel3D.newMesh(verts, indexMap)
    end
    if not mesh then return nil end

    if mesh.setTexture then mesh:setTexture(texture()) end
    ch.mesh = mesh
    ch.vertexCount = #verts
    if not modernGrass then
      -- Keep and mutate this same table for every sway tick; no per-frame
      -- vertex-table allocations.
      ch.animVerts = verts
      ch.bases = bases
    end
    proxy.builtChunks = proxy.builtChunks + 1
    proxy.builtVertices = proxy.builtVertices + #verts
    return mesh
  end

  -------------------------------------------------------------- camera cull

  local function transformPoint(model, x, y, z)
    if type(model) ~= "table" or #model < 12 then return x, y, z end
    return model[1] * x + model[2] * y + model[3] * z + model[4],
           model[5] * x + model[6] * y + model[7] * z + model[8],
           model[9] * x + model[10] * y + model[11] * z + model[12]
  end

  local function projectPoint(model, x, y, z)
    local wx, wy, wz = transformPoint(model, x, y, z)
    return Voxel3D.project(wx, wy, wz)
  end

  local function currentRenderSize()
    if type(Voxel3D.size) == "function" then
      local w, h = Voxel3D.size()
      if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
        return w, h
      end
    end
    -- Dramatic Shape 1.1.x predates Voxel3D.size(), but exposes the active
    -- canvas. Its dimensions are the coordinate space returned by project().
    if type(Voxel3D.canvas) == "function" then
      local c = Voxel3D.canvas()
      if c and type(c.getDimensions) == "function" then
        local ok, w, h = pcall(c.getDimensions, c)
        if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
          return w, h
        end
      end
    end
    return nil
  end

  local function chunkVisible(ch, model)
    if type(Voxel3D.project) ~= "function" then return true end
    local w, h = currentRenderSize()
    if not w then return true end

    local minSX, minSY = math.huge, math.huge
    local maxSX, maxSY = -math.huge, -math.huge
    local any = false

    -- Four base corners plus four top corners. Eight cheap matrix projections
    -- per 64px chunk are dramatically cheaper than vertex-shading every OBJ
    -- in an off-screen field, and remain conservative under camera tilt.
    local xs = { ch.minX, ch.maxX }
    local zs = { ch.minZ, ch.maxZ }
    local ys = { ch.minY, ch.maxY }
    for _, y in ipairs(ys) do
      for _, z in ipairs(zs) do
        for _, x in ipairs(xs) do
          local sx, sy = projectPoint(model, x, y, z)
          if sx and sy then
            any = true
            minSX, maxSX = math.min(minSX, sx), math.max(maxSX, sx)
            minSY, maxSY = math.min(minSY, sy), math.max(maxSY, sy)
          end
        end
      end
    end

    -- Near-plane edge cases are rare in this camera, but drawing rather than
    -- popping is the safe failure mode if no corner could be projected.
    if not any then return true end

    local m = CULL_MARGIN_PIXELS
    return maxSX >= -m and minSX <= w + m and maxSY >= -m and minSY <= h + m
  end

  ------------------------------------------------------------- legacy sway

  local function legacyClock60()
    -- Quantize wall-clock time to exactly 60 animation samples per second.
    -- This is independent of game-speed multipliers and avoids the old 12 Hz
    -- stepping that made Dramaless grass visibly choppy.
    local raw = love.timer and love.timer.getTime and love.timer.getTime() or os.clock()
    local tick = math.floor(raw * LEGACY_ANIM_HZ)
    return tick, tick * LEGACY_ANIM_STEP
  end

  local function animateLegacyChunk(ch, tick, now)
    local bases, rows, mesh = ch.bases, ch.animVerts, ch.mesh
    if not (bases and rows and mesh and mesh.setVertices) then return end
    if ch.lastAnimStep == tick then return end
    ch.lastAnimStep = tick

    -- Preserve the old wave exactly, but use sin(t+a) so the expensive trig
    -- is evaluated twice per visible chunk instead of once per OBJ vertex.
    local t = now * LEGACY_SWAY_SPEED
    local sinT, cosT = math.sin(t), math.cos(t)
    local amp = LEGACY_SWAY_PIXELS
    for i, b in ipairs(bases) do
      local wave = sinT * b.phaseCos + cosT * b.phaseSin
      local sway = wave * amp * b.bend
      local row = rows[i]
      row[1] = b.x + sway
      row[2] = b.y
      row[3] = b.z + sway * 0.22
      -- UV/shade columns never change.
    end
    pcall(mesh.setVertices, mesh, rows)
  end

  -------------------------------------------------------------- replacement

  local originalGrass = ChunkMesher.grass
  local originalDraw = Voxel3D.draw

  local function replacementGrass(map)
    if not (map and map.id) then return nil end
    local proxy = mapProxies[map.id]
    if proxy and proxy.map == map then return proxy end

    -- Dramaless builds map/grass data asynchronously. Wait until its native
    -- grass slot exists before querying Structures so this addon never turns
    -- a budgeted background build into a synchronous hitch. The native mesh
    -- is only used as a readiness signal and is never drawn once our proxy is
    -- active.
    if targetId == "DRAMALESS_SHAPE" then
      local okReady, nativeReady = pcall(originalGrass, map)
      if not okReady or not nativeReady then return nil end
    end

    local ok, built = pcall(makeProxy, map)
    if not ok then
      mod.log:error("OBJ grass layout failed on %s: %s", tostring(map.id), tostring(built))
      -- Never return the native grass. A failure remains visually obvious.
      return nil
    end

    mapProxies[map.id] = built
    mod.log:info(
      "OBJ grass ACTIVE on %s: %d tufts in %d chunks (%s, %s API)",
      tostring(map.id), built.count, #built.chunks, tostring(built.source),
      modernGrass and "modern" or "legacy")
    return built
  end

  ChunkMesher.grass = replacementGrass
  ChunkMesher._grassObjReplacerV3 = replacementGrass

  local function evictIdle(proxy)
    if proxy.drawCounter % EVICT_SCAN_PERIOD ~= 0 then return end
    for _, ch in ipairs(proxy.chunks) do
      if ch.mesh and proxy.drawCounter - ch.lastSeen > EVICT_AFTER_DRAWS then
        releaseChunk(ch)
      end
    end
  end

  local function drawProxy(proxy, model, pull, sunModel)
    proxy.drawCounter = proxy.drawCounter + 1
    local legacyTick, legacyNow = nil, nil
    if not modernGrass then
      legacyTick, legacyNow = legacyClock60()
    end

    for _, ch in ipairs(proxy.chunks) do
      if chunkVisible(ch, model) then
        ch.lastSeen = proxy.drawCounter
        local mesh = buildChunk(proxy, ch)
        if mesh then
          if not modernGrass then animateLegacyChunk(ch, legacyTick, legacyNow) end
          -- Texture was attached once in buildChunk; passing nil avoids
          -- mesh:setTexture() on every visible chunk every frame.
          originalDraw(mesh, nil, model, pull, sunModel)
        end
      end
    end
    evictIdle(proxy)
  end

  Voxel3D.draw = function(mesh, tex, model, pull, sunModel)
    if not (type(mesh) == "table" and mesh._marker == proxyMarker) then
      return originalDraw(mesh, tex, model, pull, sunModel)
    end

    if type(Voxel3D.seams) == "function" then Voxel3D.seams(false) end
    if type(Voxel3D.glass) == "function" then Voxel3D.glass(false) end

    local ok, err = pcall(drawProxy, mesh, model, pull, sunModel)

    if type(Voxel3D.glass) == "function" then Voxel3D.glass(true) end
    if type(Voxel3D.seams) == "function" then Voxel3D.seams(true) end
    if not ok then error(err, 0) end
  end
  Voxel3D._grassObjReplacerV3Draw = Voxel3D.draw

  ----------------------------------------------------------- self-heal/cache

  mod.events:on("map.reloaded", function(payload)
    local id = payload and (payload.mapId or (payload.map and payload.map.id))
    if id then clearMap(id) else clearMap() end
  end)

  -- Very cheap insurance against another addon/hot reload replacing either
  -- seam after us. No geometry work happens here.
  mod.hooks:wrap("input.step", function(next, game, dt)
    if ChunkMesher.grass ~= replacementGrass then
      ChunkMesher.grass = replacementGrass
    end
    if Voxel3D.draw ~= Voxel3D._grassObjReplacerV3Draw then
      Voxel3D.draw = Voxel3D._grassObjReplacerV3Draw
    end
    return next(game, dt)
  end)

  -------------------------------------------------------------- diagnostics

  mod.exports.installed = true
  mod.exports.optimized = true
  mod.exports.voxelMod = targetId
  mod.exports.voxelVersion = dep.version
  mod.exports.bridgeMode = bridgeMode
  mod.exports.apiMode = modernGrass and "modern-grass-wind-chunked"
                                    or "legacy-cpu-wind-chunked"
  mod.exports.model = stats
  mod.exports.chunkWorld = CHUNK_WORLD
  mod.exports.legacyWindHz = LEGACY_ANIM_HZ
  mod.exports.windSpeed = GRASS_SWAY_SPEED
  mod.exports.forceRebuild = function(mapId) clearMap(mapId) end
  mod.exports.cacheStats = function()
    local maps, chunks, built, tufts, vertices = 0, 0, 0, 0, 0
    for _, proxy in pairs(mapProxies) do
      maps = maps + 1
      tufts = tufts + (proxy.count or 0)
      for _, ch in ipairs(proxy.chunks or {}) do
        chunks = chunks + 1
        if ch.mesh then
          built = built + 1
          vertices = vertices + (ch.vertexCount or 0)
        end
      end
    end
    return { maps = maps, chunks = chunks, builtChunks = built,
             tufts = tufts, residentVertices = vertices }
  end

  mod.log:info(
    "GRASS OBJ REPLACER V3.4: target=%s %s bridge=%s mode=%s OBJ=%d tris, %d indexed verts (was %d), chunk=%dpx",
    tostring(targetId), tostring(dep.version), tostring(bridgeMode),
    modernGrass and "modern" or "legacy", stats.triangles,
    stats.uniqueVertices, stats.expandedVertices, CHUNK_WORLD)
end


-- HD Grass + LGPE Flowers Combined v1.0.0 - Flower installer
-- Fresh standalone extraction of the older combined flower replacement that
-- previously replaced the native voxel flowers successfully.

local function installFlowers(mod)
  local dep = mod.find("DRAMALESS_SHAPE") or mod.find("DRAMATIC_SHAPE")
  assert(dep, "LGPE Flower Replacer needs DRAMALESS_SHAPE or DRAMATIC_SHAPE enabled")

  local targetId = dep.id
  local ChunkMesher, Structures, Voxel3D
  local bridgeMode

  local function isChunkMesher(t)
    return type(t) == "table"
      and type(t.flowers) == "function"
      and type(t.request) == "function"
      and type(t.invalidate) == "function"
  end

  local function isVoxel3D(t)
    return type(t) == "table"
      and type(t.draw) == "function"
      and type(t.newMesh) == "function"
      and type(t.project) == "function"
  end

  local function isStructures(t)
    return type(t) == "table"
      and type(t.forMap) == "function"
      and type(t.invalidate) == "function"
  end

  local function findUpvalueTable(fn, predicate, depth, seen)
    if type(fn) ~= "function" or not (debug and debug.getupvalue) then return nil end
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    depth = depth or 0
    local i = 1
    while true do
      local name, value = debug.getupvalue(fn, i)
      if name == nil then break end
      if type(value) == "table" and predicate(value) then return value end
      if depth > 0 and type(value) == "function" then
        local hit = findUpvalueTable(value, predicate, depth - 1, seen)
        if hit then return hit end
      end
      i = i + 1
    end
    return nil
  end

  local direct = dep.exports and dep.exports.lib
  if type(direct) == "table" and type(direct.require) == "function" then
    ChunkMesher = assert(direct.require("ChunkMesher"), "missing ChunkMesher")
    Structures = assert(direct.require("Structures"), "missing Structures")
    Voxel3D = assert(direct.require("Voxel3D"), "missing Voxel3D")
    bridgeMode = "exports.lib"
  else
    local pipe = mod.content.render_pipelines:get("st_voxel")
              or mod.content.render_pipelines:get("voxel")
    assert(type(pipe) == "table", "voxel pipeline was not registered before LGPE Flower Replacer")
    assert(debug and type(debug.getupvalue) == "function",
      "Dramaless compatibility needs Lua debug.getupvalue")

    local seeds = { pipe.invalidate, pipe.drawWorld, pipe.update, pipe.available }
    for _, fn in ipairs(seeds) do
      if not ChunkMesher then ChunkMesher = findUpvalueTable(fn, isChunkMesher, 5) end
      if not Voxel3D then Voxel3D = findUpvalueTable(fn, isVoxel3D, 5) end
    end
    assert(isChunkMesher(ChunkMesher), "could not locate live Dramaless ChunkMesher")
    assert(isVoxel3D(Voxel3D), "could not locate live Dramaless Voxel3D")

    Structures = findUpvalueTable(ChunkMesher.geometry, isStructures, 6)
              or findUpvalueTable(ChunkMesher.build, isStructures, 6)
              or findUpvalueTable(ChunkMesher.get, isStructures, 7)
    bridgeMode = "pipeline-upvalues"
  end

  assert(isChunkMesher(ChunkMesher), "ChunkMesher.flowers unavailable")
  assert(isStructures(Structures), "Structures.forMap unavailable")
  assert(isVoxel3D(Voxel3D), "Voxel3D API unavailable")

  local FLOWER_CLUSTER_WIDTH = 7.5
  local FLOWER_VERTICAL_SCALE = 1.0
  local ANIM_HZ = 60
  local WIND_SPEED = 4.2
  local WIND_PIXELS = 0.55
  local FLOWER_MODEL_SPEC = {
    label = "LGPE Flower Cluster",
    obj = "assets/flower_cluster.obj",
    texture = "assets/flower.png",
  }

  local function parseIndex(token, count)
    local n = tonumber(token)
    if not n then return nil end
    if n < 0 then return count + n + 1 end
    return n
  end

  local function parseObj(spec)
    local text = assert(mod:read(spec.obj), "could not read " .. spec.obj)
    local positions, uvs = {}, {}
    local faces = {}
    local currentMaterial = nil
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

    for line in text:gmatch("[^\r\n]+") do
      local x, y, z = line:match("^v%s+([%+%-%.%deE]+)%s+([%+%-%.%deE]+)%s+([%+%-%.%deE]+)")
      if x then
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        positions[#positions + 1] = { x, y, z }
        minX, minY, minZ = math.min(minX, x), math.min(minY, y), math.min(minZ, z)
        maxX, maxY, maxZ = math.max(maxX, x), math.max(maxY, y), math.max(maxZ, z)
      else
        local u, v = line:match("^vt%s+([%+%-%.%deE]+)%s+([%+%-%.%deE]+)")
        if u then
          uvs[#uvs + 1] = { tonumber(u), tonumber(v) }
        else
          local material = line:match("^usemtl%s+(%S+)")
          if material then
            currentMaterial = material
          elseif line:match("^f%s+") then
            local refs = {}
            for ref in line:gmatch("%S+") do
              if ref ~= "f" then
                local vi, ti = ref:match("^([^/]+)/([^/]*)")
                if not vi then vi = ref:match("^([^/]+)") end
                refs[#refs + 1] = { vi = vi, ti = ti }
              end
            end
            if #refs >= 3 then
              for i = 2, #refs - 1 do
                faces[#faces + 1] = {
                  material = currentMaterial,
                  refs = { refs[1], refs[i], refs[i + 1] },
                }
              end
            end
          end
        end
      end
    end

    assert(#positions > 0 and #faces > 0, spec.label .. " OBJ has no usable geometry")

    local cx = (minX + maxX) * 0.5
    local width = math.max(0.0001, maxX - minX)
    local depth = math.max(0.0001, maxZ - minZ)
    local height = math.max(0.0001, maxY - minY)

    local groups = {}
    local triangles = 0
    for _, face in ipairs(faces) do
      local material = face.material or ""
      if material == "body" then
        local group = groups[material]
        if not group then
          group = { material = material, vertices = {}, indices = {}, byKey = {} }
          groups[material] = group
        end
        triangles = triangles + 1
        for _, ref in ipairs(face.refs) do
          local vi = parseIndex(ref.vi, #positions)
          local ti = ref.ti and ref.ti ~= "" and parseIndex(ref.ti, #uvs) or nil
          local pv = positions[vi]
          assert(pv, spec.label .. " face references a missing vertex")
          local t = (ti and uvs[ti]) or { 0, 0 }
          local key = string.format("%.6f:%.6f:%.6f:%.6f:%.6f",
            pv[1], pv[2], pv[3], t[1] or 0, t[2] or 0)
          local idx = group.byKey[key]
          if not idx then
            idx = #group.vertices + 1
            group.byKey[key] = idx
            group.vertices[idx] = {
              x = pv[1] - cx,
              y = pv[2] - minY,
              z = pv[3] - maxZ,
              u = t[1] or 0,
              -- flower_cluster.obj was already converted from the source DAE
              -- with V flipped into LÖVE/image space. Do NOT flip it again.
              v = t[2] or 0,
            }
          end
          group.indices[#group.indices + 1] = idx
        end
      end
    end

    local uniqueVertices = 0
    local materials = 0
    for _, group in pairs(groups) do
      group.byKey = nil
      uniqueVertices = uniqueVertices + #group.vertices
      materials = materials + 1
    end
    assert(materials > 0, spec.label .. " OBJ produced no textured material groups")

    return {
      groups = groups,
      minX = minX, maxX = maxX,
      minY = minY, maxY = maxY,
      minZ = minZ, maxZ = maxZ,
      sourceWidth = width,
      sourceHeight = height,
      sourceDepth = depth,
      triangles = triangles,
      uniqueVertices = uniqueVertices,
    }
  end

  local function parseFlowerObj(spec)
    local parsed = parseObj {
      label = spec.label,
      obj = spec.obj,
    }

    local mat = assert(parsed.groups.body, "flower model did not produce a body material")
    local tex = mod.assets:image(spec.texture)
    assert(tex, "flower texture failed to load")
    if tex.setFilter then tex:setFilter("nearest", "nearest") end

    local verts, indices = {}, {}
    for _, vertex in ipairs(mat.vertices) do
      verts[#verts + 1] = {
        x = vertex.x, y = vertex.y, z = vertex.z,
        u = vertex.u, v = vertex.v, shade = 1.0,
      }
    end
    for _, idx in ipairs(mat.indices) do indices[#indices + 1] = idx end

    return {
      label = spec.label,
      texture = tex,
      vertices = verts,
      indices = indices,
      triangles = parsed.triangles,
      uniqueVertices = parsed.uniqueVertices,
      sourceWidth = parsed.sourceWidth,
      sourceHeight = parsed.sourceHeight,
      sourceDepth = parsed.sourceDepth,
      minX = parsed.minX, maxX = parsed.maxX,
      minY = parsed.minY, maxY = parsed.maxY,
      minZ = parsed.minZ, maxZ = parsed.maxZ,
      centerX = (parsed.minX + parsed.maxX) * 0.5,
      centerZ = (parsed.minZ + parsed.maxZ) * 0.5,
    }
  end

  local parsedFlower = parseFlowerObj(FLOWER_MODEL_SPEC)

  local function flowerRotation(tx, ty)
    return (tx * 131 + ty * 17) % 4
  end

  local function rotateXZ(x, z, steps)
    steps = steps % 4
    if steps == 0 then return x, z end
    if steps == 1 then return -z, x end
    if steps == 2 then return -x, -z end
    return z, -x
  end

  local function flowerModelBounds()
    local span = math.max(parsedFlower.sourceWidth, parsedFlower.sourceDepth)
    local scale = FLOWER_CLUSTER_WIDTH / math.max(span, 0.001)
    return scale, parsedFlower.centerX, parsedFlower.centerZ, parsedFlower.minY
  end

  local function flowerKey(tx, ty)
    return (ty + 64) * 4096 + (tx + 64)
  end

  local originalForMap = Structures.forMap
  local wrappedForMap
  wrappedForMap = function(map)
    local S = originalForMap(map)
    if not S or S._lgpeFlowerProcessed then return S end
    S._lgpeFlowerProcessed = true
    local def = map and map.def
    if not def or not S.shapeAt then return S end

    local tw, th = def.width * 4, def.height * 4
    local placements = {}
    for ty = 0, th - 1 do
      for tx = 0, tw - 1 do
        local shape = S.shapeAt[flowerKey(tx, ty)]
        if shape and shape.art == "flower" then
          placements[#placements + 1] = {
            tx = tx, ty = ty,
            wx = tx * 8 + 4,
            wz = ty * 8 + 4,
            rot = flowerRotation(tx, ty),
          }
        end
      end
    end

    S._lgpeFlowerPlacements = placements
    if #placements > 0 then S.flowerQuads = {} end
    return S
  end
  Structures.forMap = wrappedForMap

  local meshMeta = setmetatable({}, { __mode = "k" })
  local cache = {}

  local function releaseMesh(mesh)
    if mesh and mesh.release then pcall(mesh.release, mesh) end
  end

  local function clear(mapId)
    if mapId then
      local rec = cache[mapId]
      if rec then releaseMesh(rec.mesh) end
      cache[mapId] = nil
    else
      for _, rec in pairs(cache) do releaseMesh(rec.mesh) end
      cache = {}
    end
  end

  local function buildForMap(map, S)
    local placements = S and S._lgpeFlowerPlacements
    if type(placements) ~= "table" or #placements == 0 then return nil, 0 end

    local scale, cx, cz, baseY = flowerModelBounds()
    local verts, indices, bases = {}, {}, {}
    local vertCount = 0
    local maxLocalHeight = math.max(0.001, (parsedFlower.maxY or 1) - (parsedFlower.minY or 0))

    for _, p in ipairs(placements) do
      local phase = p.wx * 0.061 + p.wz * 0.037 + p.rot * 1.5707963268
      for _, v in ipairs(parsedFlower.vertices) do
        local lx = (v.x - cx) * scale
        local ly = (v.y - baseY) * scale * FLOWER_VERTICAL_SCALE
        local lz = (v.z - cz) * scale
        lx, lz = rotateXZ(lx, lz, p.rot)
        local wx, wy, wz = p.wx + lx, ly, p.wz + lz
        verts[#verts + 1] = { wx, wy, wz, v.u, v.v, v.shade }
        local h = math.max(0, math.min(1, (v.y - baseY) / maxLocalHeight))
        local pa = phase + ly * 0.18
        bases[#bases + 1] = {
          x = wx, y = wy, z = wz,
          bend = h * h,
          ps = math.sin(pa),
          pc = math.cos(pa),
        }
      end
      for _, idx in ipairs(parsedFlower.indices) do
        indices[#indices + 1] = idx + vertCount
      end
      vertCount = vertCount + #parsedFlower.vertices
    end

    local mesh = Voxel3D.newMesh(verts, indices)
    if mesh and mesh.setTexture then mesh:setTexture(parsedFlower.texture) end
    if mesh then
      meshMeta[mesh] = {
        texture = parsedFlower.texture,
        verts = verts,
        bases = bases,
        lastTick = nil,
        count = #placements,
      }
    end
    return mesh, #placements
  end


  local originalFlowers = ChunkMesher.flowers
  local replacementFlowers
  replacementFlowers = function(map)
    if not (map and map.id) then return nil end

    local S = Structures.forMap(map)
    local placements = S and S._lgpeFlowerPlacements
    if type(placements) ~= "table" or #placements == 0 then
      return originalFlowers(map)
    end

    local rec = cache[map.id]
    if rec and rec.map == map and rec.S == S and rec.mesh then return rec.mesh end

    if rec then releaseMesh(rec.mesh) end
    local mesh, count = buildForMap(map, S)
    if not mesh then return nil end
    cache[map.id] = { map = map, S = S, mesh = mesh, count = count }
    mod.log:info("LGPE FLOWERS V4.1 active on %s: %d flower tiles", tostring(map.id), count)
    return mesh
  end
  ChunkMesher.flowers = replacementFlowers

  local function animate(meta)
    local raw = love.timer and love.timer.getTime and love.timer.getTime() or os.clock()
    local tick = math.floor(raw * ANIM_HZ)
    if meta.lastTick == tick then return false end
    meta.lastTick = tick

    local t = (tick / ANIM_HZ) * WIND_SPEED
    local st, ct = math.sin(t), math.cos(t)
    for i, b in ipairs(meta.bases) do
      local wave = st * b.pc + ct * b.ps
      local sway = wave * WIND_PIXELS * b.bend
      local row = meta.verts[i]
      row[1] = b.x + sway
      row[2] = b.y
      row[3] = b.z + sway * 0.16
    end
    return true
  end

  local downstreamDraw = Voxel3D.draw
  local flowerDraw
  flowerDraw = function(mesh, tex, model, pull, sunModel)
    local meta = meshMeta[mesh]
    if not meta then
      return downstreamDraw(mesh, tex, model, pull, sunModel)
    end

    local changed = animate(meta)
    if changed and mesh.setVertices then pcall(mesh.setVertices, mesh, meta.verts) end

    if type(Voxel3D.seams) == "function" then Voxel3D.seams(false) end
    if type(Voxel3D.glass) == "function" then Voxel3D.glass(false) end
    local ok, result = pcall(downstreamDraw, mesh, meta.texture, model, pull, sunModel)
    if type(Voxel3D.glass) == "function" then Voxel3D.glass(true) end
    if type(Voxel3D.seams) == "function" then Voxel3D.seams(true) end
    if not ok then error(result, 0) end
    return result
  end
  Voxel3D.draw = flowerDraw

  -- Combined-mod composition: Grass installed first and its self-heal follows
  -- this pointer. Point it at the fully composed flower->grass draw chain so
  -- the two systems never fight each other on input.step. Later tree/building
  -- companion mods are allowed to replace this pointer with their own wrapper.
  if Voxel3D._grassObjReplacerV3Draw then
    Voxel3D._grassObjReplacerV3Draw = flowerDraw
  end

  mod.events:on("map.reloaded", function(payload)
    if payload and payload.reason == "colors" then return end
    local id = payload and (payload.mapId or (payload.map and payload.map.id))
    clear(id)
  end)

  mod.hooks:wrap("input.step", function(next, game, dt)
    local result = next(game, dt)
    if ChunkMesher.flowers ~= replacementFlowers then ChunkMesher.flowers = replacementFlowers end
    if Structures.forMap ~= wrappedForMap then Structures.forMap = wrappedForMap end
    local tree = mod.find("DRAMATIC_SHAPE_TREE_OBJ_REPLACER_V1")
    local building = mod.find("DRAMATIC_SHAPE_HGSS_BUILDING_OBJ_REPLACER_V1")
    if not tree and not building and Voxel3D.draw ~= flowerDraw then
      Voxel3D.draw = flowerDraw
    end
    return result
  end)

  pcall(Structures.invalidate)
  pcall(ChunkMesher.invalidate)

  mod.exports.flowers = {
    installed = true,
    voxelMod = targetId,
    voxelVersion = dep.version,
    bridgeMode = bridgeMode,
    windHz = ANIM_HZ,
    windSpeed = WIND_SPEED,
    windPixels = WIND_PIXELS,
    model = {
      triangles = parsedFlower.triangles,
      uniqueVertices = parsedFlower.uniqueVertices,
      sourceWidth = parsedFlower.sourceWidth,
      sourceHeight = parsedFlower.sourceHeight,
      sourceDepth = parsedFlower.sourceDepth,
      clusterWidth = FLOWER_CLUSTER_WIDTH,
    },
  }
  mod.exports.forceFlowerRebuild = function(mapId)
    clear(mapId)
    if type(Structures.invalidate) == "function" then pcall(Structures.invalidate, mapId) end
    if type(ChunkMesher.invalidate) == "function" then
      if mapId then return ChunkMesher.invalidate(mapId) end
      return ChunkMesher.invalidate()
    end
  end

  mod.log:info(
    "LGPE FLOWER V4.1.0: target=%s %s bridge=%s model=%d tris/%d verts, footprint=%.1fpx, wind=%dHz",
    tostring(targetId), tostring(dep.version), tostring(bridgeMode),
    parsedFlower.triangles, parsedFlower.uniqueVertices, FLOWER_CLUSTER_WIDTH, ANIM_HZ)
end


return function(mod)
  installGrass(mod)
  installFlowers(mod)
  mod.exports.combined = true
  mod.exports.combinedVersion = "1.0.0"
  mod.log:info("HD GRASS + LGPE FLOWERS COMBINED v1.0.0 installed")
end
