-- Imports only the prepared manifest's exact paths into its named catalog.
-- No device scan, source copy, metadata writeback, or network operation occurs.
local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrDigest = import "LrDigest"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

LrTasks.startAsyncTask(function()
  local job = dofile(LrPathUtils.child(_PLUGIN.path, "Job.lua"))
  local log
  local function record(message)
    log:write(message .. "\n")
    log:flush()
  end
  local ok, message = LrTasks.pcall(function()
    local catalog = LrApplication.activeCatalog()
    assert(catalog:getPath() == job.catalog, "The prepared research catalog must be active")
    assert(not LrFileUtils.exists(job.output), "Output already exists; preserve the previous evidence")
    assert(#job.cases > 0 and #job.cases <= 1000, "Invalid acquisition size")

    -- Validate every prepared input before adding even the first catalog entry.
    for _, case in ipairs(job.cases) do
      assert(LrPathUtils.parent(case.input) == job.inputs, "Unexpected input directory")
      local input = assert(io.open(case.input, "rb"))
      local digest = LrDigest.SHA256.init()
      while true do
        local bytes = input:read(1024 * 1024)
        if not bytes then break end
        digest:update(bytes)
      end
      input:close()
      assert(digest:digest() == case.sha256, "Prepared input changed: " .. case.id)
    end

    LrFileUtils.createAllDirectories(job.output)
    log = assert(io.open(LrPathUtils.child(job.output, "acquisition.log"), "w"))
    record("catalog\t" .. catalog:getPath())
    record("requested\t" .. #job.cases)
    local photos = {}
    for _, case in ipairs(job.cases) do
      local photo = catalog:findPhotoByPath(case.input)
      if not photo then
        catalog:withWriteAccessDo("Add prepared Brightroom reference", function()
          photo = catalog:addPhoto(case.input)
        end, { timeout = 30 })
      end
      assert(photo, "Could not add prepared input: " .. case.id)
      local settings = photo:getDevelopSettings()
      for key, expected in pairs(case.parameters) do
        assert(settings[key] == expected,
          "Imported parameter mismatch: " .. case.id .. " / " .. key)
      end
      photos[#photos + 1] = photo
      record("added\t" .. case.id)
    end

    local session = LrExportSession {
      photosToExport = photos,
      exportSettings = {
        LR_exportServiceProvider = "com.adobe.ag.export.file",
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = job.output,
        LR_export_useSubfolder = false,
        LR_collisionHandling = "skip",
        LR_format = "TIFF",
        LR_export_bitDepth = 16,
        LR_export_colorSpace = "ProPhotoRGB",
        LR_tiff_compressionMethod = "compressionMethod_None",
        LR_tiff_preserveTransparency = false,
        LR_size_doConstrain = false,
        LR_outputSharpeningOn = false,
        LR_useWatermark = false,
        LR_enableHDRDisplay = false,
        LR_renamingTokensOn = false,
        LR_extensionCase = "lowercase",
        LR_minimizeEmbeddedMetadata = false,
        LR_metadata_keywordOptions = "flat",
        LR_reimportExportedPhoto = false,
        LR_export_postProcessing = "doNothing",
      },
    }
    local count = 0
    for _, rendition in session:renditions() do
      local rendered, path = rendition:waitForRender()
      assert(rendered and not rendition.wasSkipped, tostring(path))
      assert(LrPathUtils.parent(path) == job.output, "Unexpected export destination")
      assert(LrFileUtils.exists(path), "Rendition is missing")
      count = count + 1
      record("exported\t" .. path)
    end
    assert(count == #job.cases, "Incomplete acquisition")
    record("complete\t" .. count)
  end)
  if not ok and log then record("failed\t" .. tostring(message)) end
  if log then log:close() end
  LrDialogs.message("Brightroom references", ok and "Acquisition complete. Inspect and register the exported settings before measuring." or tostring(message), ok and "info" or "critical")
end)
