package lime.tools;

import hxp.Haxelib;
import hxp.Log;
import hxp.Path;
import hxp.System;
import haxe.io.Bytes;
import lime.graphics.Image;
import lime.graphics.ImageFileFormat;
import lime.graphics.PixelFormat;
import lime.tools.Asset;
import lime.tools.HXProject;
import sys.io.File;
import sys.FileSystem;

class ASTCTextureHelper
{
	private static inline var RAW_ASTC_EXTENSION:String = "astc";
	private static inline var KTX_ASTC_EXTENSION:String = "astc.ktx";
	private static inline var KTX_HEADER_SIZE:Int = 64;
	private static inline var ASTC_HEADER_SIZE:Int = 16;

	private static var checkedEncoder:Bool = false;
	private static var encoderPath:String = null;
	private static var compressorAvailable:Null<Bool> = null;
	private static var missingWarned:Bool = false;
	private static var converted:Int = 0;
	private static var skipped:Int = 0;
	private static var failed:Int = 0;
	private static var strippedPNG:Int = 0;
	private static var strippedPNGAssets:Array<Asset> = [];
	private static var readablePNGAssets:Array<Asset> = [];

	public static function prepareProjectAssets(project:HXProject, targetDirectory:String):Void
	{
		converted = 0;
		skipped = 0;
		failed = 0;
		strippedPNG = 0;
		strippedPNGAssets = [];
		readablePNGAssets = [];

		if (!isEnabled(project))
			return;

		Log.info("", " - \x1b[1mASTC texture conversion enabled:\x1b[0m block=" + getBlockSize(project)
			+ " quality=" + getQuality(project) + " colorprofile=" + getColorProfile(project)
			+ " premultiplyAlpha=" + getPremultiplyAlpha(project)
			+ " smartBlocks=" + getSmartBlocks(project) + " detailBlock=" + getDetailBlockSize(project)
			+ " largeBlock=" + getLargeBlockSize(project) + " hugeBlock=" + getHugeBlockSize(project)
			+ " container=" + getTextureExtension(project)
			+ " strict=" + getStrict(project));

		if (!hasEncoder())
		{
			if (getStrict(project))
				Log.error("ASTC strict mode is enabled but no ASTC encoder was found. Install `astc-compressor` or set ASTC_ENCODER.");
			warnMissingEncoder();
			return;
		}

		var astcCache = Path.combine(targetDirectory, "obj/astc-assets");
		var existing:Map<String, Bool> = [];
		for (asset in project.assets)
			existing.set(asset.resourceName, true);

		var stripPNG = project.config.getBool("android.astc-strip-png", true);
		var strict = getStrict(project);
		var finalAssets:Array<Asset> = [];
		for (asset in project.assets)
		{
			if (!isPNGAsset(asset, asset.resourceName))
			{
				finalAssets.push(asset);
				continue;
			}

			if (asset.sourcePath == null || asset.sourcePath == "")
			{
				if (strict)
					Log.error("ASTC strict mode cannot convert PNG asset without a source path: " + asset.resourceName);
				finalAssets.push(asset);
				continue;
			}

			if (shouldKeepReadablePNG(asset))
			{
				rememberReadablePNG(asset);
				finalAssets.push(asset);
				continue;
			}

			var textureExtension = getTextureExtension(project);
			var resourceName = replaceExtension(asset.resourceName, textureExtension);
			var output = Path.combine(astcCache, resourceName);
			if (existing.exists(resourceName))
			{
				var hasCompressedOutput = FileSystem.exists(output) || tryCompressPNG(project, asset.sourcePath, output);
				if (hasCompressedOutput)
				{
					var cachedAsset = asset.clone();
					cachedAsset.sourcePath = output;
					cachedAsset.resourceName = resourceName;
					cachedAsset.targetPath = replaceExtension(asset.targetPath, textureExtension);
					cachedAsset.id = cachedAsset.targetPath;
					cachedAsset.flatName = replaceExtension(asset.flatName, textureExtension);
					cachedAsset.format = usesKTXContainer(project) ? "ktx" : RAW_ASTC_EXTENSION;
					cachedAsset.type = BINARY;
					cachedAsset.embed = false;
					cachedAsset.encrypt = false;
					finalAssets.push(cachedAsset);
				}
				else if (strict)
				{
					Log.error("ASTC strict mode failed to convert duplicate PNG asset: " + asset.sourcePath + ". PNG fallback is disabled.");
				}

				if (stripPNG)
					rememberStrippedPNG(asset);
				else
					finalAssets.push(asset);
				continue;
			}

			if (tryCompressPNG(project, asset.sourcePath, output))
			{
				var astcAsset = asset.clone();
				astcAsset.sourcePath = output;
				astcAsset.resourceName = resourceName;
				astcAsset.targetPath = replaceExtension(asset.targetPath, textureExtension);
				astcAsset.id = astcAsset.targetPath;
				astcAsset.flatName = replaceExtension(asset.flatName, textureExtension);
				astcAsset.format = usesKTXContainer(project) ? "ktx" : RAW_ASTC_EXTENSION;
				astcAsset.type = BINARY;
				astcAsset.embed = false;
				astcAsset.encrypt = false;
				finalAssets.push(astcAsset);
				existing.set(resourceName, true);
				if (stripPNG)
					rememberStrippedPNG(asset);
				else
					finalAssets.push(asset);
			}
			else
			{
				if (strict)
					Log.error("ASTC strict mode failed to convert PNG asset: " + asset.sourcePath + ". PNG fallback is disabled.");
				else
					finalAssets.push(asset);
			}
		}

		project.assets = finalAssets;
	}

	public static function getStrippedPNGAssets():Array<Asset>
	{
		return strippedPNGAssets;
	}

	public static function getReadablePNGAssets():Array<Asset>
	{
		return readablePNGAssets;
	}

	private static function rememberStrippedPNG(asset:Asset):Void
	{
		strippedPNG++;
		if (asset != null)
			strippedPNGAssets.push(asset.clone());
	}

	private static function rememberReadablePNG(asset:Asset):Void
	{
		if (asset != null)
			readablePNGAssets.push(asset.clone());
	}

	private static function shouldKeepReadablePNG(asset:Asset):Bool
	{
		return false;
	}

	private static function shouldKeepReadablePNGPath(value:String):Bool
	{
		if (value == null || value == "")
			return false;

		var path = normalize(value).toLowerCase();
		if (!StringTools.startsWith(path, "/"))
			path = "/" + path;

		return StringTools.endsWith(path, "/images/menus/alphabet.png")
			|| StringTools.endsWith(path, "/images/menus/alphabet-bold.png")
			|| StringTools.endsWith(path, "/images/alphabet.png")
			|| StringTools.endsWith(path, "/images/alphabet-bold.png")
			|| path.indexOf("/images/alphabet/") != -1
			|| path.indexOf("/images/menus/options/") != -1
			|| path.indexOf("/images/game/notes/") != -1
			|| path.indexOf("/images/stages/") != -1 && path.indexOf("/ui/arrows") != -1
			|| path.indexOf("/images/tmk/arrows/") != -1;
	}

	public static function finish(project:HXProject):Void
	{
		if (!isEnabled(project))
			return;

		Log.info("", " - \x1b[1mASTC texture conversion summary:\x1b[0m " + converted + " converted, " + skipped + " cached, "
			+ failed + " failed, " + strippedPNG + " png stripped");
	}

	public static function compressCopiedAsset(project:HXProject, asset:Asset, destination:String):Void
	{
		if (!isEnabled(project) || !isPNGAsset(asset, destination))
			return;

		var output = replaceExtension(destination, getTextureExtension(project));
		compressPNG(project, destination, output);
	}

	private static function compressPNG(project:HXProject, input:String, output:String):Bool
	{
		if (input == null || input == "" || !FileSystem.exists(input))
			return false;

		if (isFastCacheValid(project, input, output))
		{
			cleanupPreparedInput(output + ".premul.png", input);
			skipped++;
			return true;
		}

		var finalOutput = output;
		var rawOutput = getRawASTCOutput(output);
		if (tryReuseRawASTCAsKTX(project, input, rawOutput, finalOutput))
			return true;

		var info = analyzeInput(input);
		var blockSize = getEffectiveBlockSize(project, input, info);
		var meta = getMeta(project, input, blockSize);
		var legacyMeta = getLegacyMeta(project, blockSize);
		var existingMeta = FileSystem.exists(getMetaPath(output)) ? File.getContent(getMetaPath(output)) : null;

		if (FileSystem.exists(output)
			&& !System.isNewer(input, output)
			&& (existingMeta == meta || existingMeta == legacyMeta))
		{
			cleanupPreparedInput(output + ".premul.png", input);
			saveMeta(getMetaPath(output), meta);
			skipped++;
			return true;
		}

		var canReuseRawOutput = finalOutput != rawOutput
			&& FileSystem.exists(rawOutput)
			&& !System.isNewer(input, rawOutput)
			&& isReusableRawASTC(rawOutput);

		System.mkdir(Path.directory(finalOutput));
		System.mkdir(Path.directory(rawOutput));
		if (FileSystem.exists(output))
			FileSystem.deleteFile(output);
		if (FileSystem.exists(getMetaPath(output)))
			FileSystem.deleteFile(getMetaPath(output));
		if (finalOutput != rawOutput && FileSystem.exists(rawOutput) && !canReuseRawOutput)
			FileSystem.deleteFile(rawOutput);

		var ok = false;
		if (canReuseRawOutput)
		{
			ok = true;
		}
		else
		{
			var encoder = getDirectEncoder();
			var source = prepareInputPNG(project, input, finalOutput);
			if (FileSystem.exists(rawOutput) && !System.isNewer(input, rawOutput))
				ok = true;
			else if (encoder != null && encoder != "")
				ok = compressWithAstcenc(project, encoder, source, rawOutput, blockSize);
			else
				ok = compressWithAstcCompressor(project, source, rawOutput, blockSize);
			cleanupPreparedInput(source, input);
		}

		if (ok && finalOutput != rawOutput)
			ok = wrapASTCAsKTX(rawOutput, finalOutput);

		if (ok && FileSystem.exists(finalOutput))
		{
			saveMeta(getMetaPath(finalOutput), meta);
			converted++;
			Log.info("", " - \x1b[1mWriting ASTC texture:\x1b[0m " + finalOutput + " block=" + blockSize
				+ (finalOutput != rawOutput ? " container=ktx" : ""));
			return true;
		}
		else
		{
			failed++;
			Log.warn("ASTC conversion failed: " + input);
			return false;
		}
	}

	private static function isEnabled(project:HXProject):Bool
	{
		return project != null && project.config.getBool("android.astc-textures", true);
	}

	private static function usesKTXContainer(project:HXProject):Bool
	{
		return project != null && project.config.getBool("android.astc-ktx", true);
	}

	private static function getTextureExtension(project:HXProject):String
	{
		return usesKTXContainer(project) ? KTX_ASTC_EXTENSION : RAW_ASTC_EXTENSION;
	}

	private static function getRawASTCOutput(output:String):String
	{
		if (output == null || output == "")
			return output;

		var lower = normalize(output).toLowerCase();
		if (StringTools.endsWith(lower, "." + KTX_ASTC_EXTENSION))
			return output.substr(0, output.length - ".ktx".length);
		if (StringTools.endsWith(lower, ".ktx"))
			return Path.withoutExtension(output) + "." + RAW_ASTC_EXTENSION;
		return output;
	}

	private static function isPNGAsset(asset:Asset, destination:String):Bool
	{
		if (asset == null || destination == null)
			return false;

		var ext = Path.extension(destination);
		return ext != null && ext.toLowerCase() == "png";
	}

	private static function getBlockSize(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-blocksize", "4x4"), "4x4");
	}

	private static function getDetailBlockSize(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-detail-blocksize", "4x4"), "4x4");
	}

	private static function getLargeBlockSize(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-large-blocksize", "8x8"), "8x8");
	}

	private static function getHugeBlockSize(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-huge-blocksize", "10x10"), "10x10");
	}

	private static function getQuality(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-quality", "thorough"), "thorough");
	}

	private static function getColorProfile(project:HXProject):String
	{
		var profile = sanitize(project.config.getString("android.astc-colorprofile", "cl"), "cl");
		if (StringTools.startsWith(profile, "-"))
			profile = profile.substr(1);
		return profile;
	}

	private static function getPremultiplyAlpha(project:HXProject):Bool
	{
		return project.config.getBool("android.astc-premultiply-alpha", true);
	}

	/**
		Long asset paths can blow past the Windows MAX_PATH limit and make
		low-level file operations throw. Treat any crash during compression
		as a failed conversion so the caller falls back to the plain PNG.
	**/
	private static function tryCompressPNG(project:HXProject, input:String, output:String):Bool
	{
		try
		{
			return compressPNG(project, input, output);
		}
		catch (e:Dynamic)
		{
			Log.warn("ASTC conversion crashed: " + input + " (" + Std.string(e) + ")");
			return false;
		}
	}

	private static function getStrict(project:HXProject):Bool
	{
		return project.config.getBool("android.astc-strict", project.config.getBool("android.astc-strip-png", true));
	}

	private static function getSmartBlocks(project:HXProject):Bool
	{
		return project.config.getBool("android.astc-smart-blocks", true);
	}

	private static function isFastCacheValid(project:HXProject, input:String, output:String):Bool
	{
		if (!FileSystem.exists(output) || !FileSystem.exists(getMetaPath(output)))
			return false;

		try
		{
			var cachedMeta = File.getContent(getMetaPath(output));
			if (StringTools.startsWith(cachedMeta, getCacheHeader(project, input)))
				return true;

			return tryUpgradeLegacyCache(project, input, output, cachedMeta);
		}
		catch (e:Dynamic) {}

		return false;
	}

	private static function tryReuseRawASTCAsKTX(project:HXProject, input:String, rawOutput:String, finalOutput:String):Bool
	{
		if (finalOutput == rawOutput || !usesKTXContainer(project))
			return false;
		if (!FileSystem.exists(rawOutput))
			return false;
		if (!isReusableRawASTC(rawOutput))
			return false;

		try
		{
			var rawMetaPath = getMetaPath(rawOutput);
			var rawMeta = FileSystem.exists(rawMetaPath) ? File.getContent(rawMetaPath) : null;
			if (rawMeta != null)
			{
				if (System.isNewer(input, rawOutput) && !sourceMatchesRawMeta(input, rawMeta))
					return false;

				if (!StringTools.startsWith(rawMeta, getCacheHeader(project, input))
					&& !hasMatchingSettings(project, rawMeta)
					&& !tryUpgradeLegacyCache(project, input, rawOutput, rawMeta))
					return false;

				rawMeta = File.getContent(rawMetaPath);
			}
			else if (System.isNewer(input, rawOutput))
			{
				return false;
			}

			var blockSize = rawMeta != null ? getMetaValue(rawMeta, "block") : null;
			if (blockSize == null || blockSize == "")
				blockSize = getRawASTCBlockSize(rawOutput);
			if (blockSize == null || blockSize == "")
				blockSize = getBlockSize(project);

			var hadOutput = FileSystem.exists(finalOutput) && isKTXFile(finalOutput);
			var needsWrap = !hadOutput || System.isNewer(rawOutput, finalOutput) || System.isNewer(input, finalOutput);
			if (needsWrap && !wrapASTCAsKTX(rawOutput, finalOutput))
				return false;

			saveMeta(getMetaPath(finalOutput), getMeta(project, input, blockSize));
			if (needsWrap)
			{
				converted++;
				Log.info("", " - \x1b[1mWriting ASTC texture:\x1b[0m " + finalOutput + " block=" + blockSize + " container=ktx cached");
			}
			else
			{
				skipped++;
			}
			return true;
		}
		catch (e:Dynamic)
		{
			return false;
		}
	}

	private static function isReusableRawASTC(path:String):Bool
	{
		try
		{
			if (path == null || !FileSystem.exists(path))
				return false;

			var bytes = File.getBytes(path);
			return bytes != null && bytes.length > ASTC_HEADER_SIZE && hasValidASTCHeader(bytes);
		}
		catch (e:Dynamic) {}

		return false;
	}

	private static function sourceMatchesRawMeta(input:String, meta:String):Bool
	{
		try
		{
			var source = getMetaValue(meta, "source");
			if (source == null || source == "")
				return false;

			var parts = source.split("|");
			if (parts.length < 2)
				return false;

			var stat = FileSystem.stat(input);
			if (Std.string(stat.size) != parts[1])
				return false;

			var inputPath = normalize(input);
			var metaPath = normalize(parts[0]);
			return inputPath == metaPath || StringTools.endsWith(inputPath, "/" + metaPath) || StringTools.endsWith(metaPath, "/" + inputPath);
		}
		catch (e:Dynamic) {}

		return false;
	}

	private static function hasMatchingSettings(project:HXProject, meta:String):Bool
	{
		if (meta == null || meta == "")
			return false;

		var expected = getSettingsSignature(project);
		var expectedWithoutContainer = removeSettingPart(expected, "container=");
		for (line in meta.split("\n"))
		{
			if (!StringTools.startsWith(line, "settings="))
				continue;

			var settings = line.substr("settings=".length);
			if (settings == expected || removeSettingPart(settings, "container=") == expectedWithoutContainer)
				return true;
		}

		return false;
	}

	private static function removeSettingPart(settings:String, prefix:String):String
	{
		if (settings == null || settings == "")
			return settings;

		var parts = [];
		for (part in settings.split("|"))
		{
			if (!StringTools.startsWith(part, prefix))
				parts.push(part);
		}

		return parts.join("|");
	}

	private static function getRawASTCBlockSize(path:String):String
	{
		try
		{
			var bytes = File.getBytes(path);
			if (bytes != null && bytes.length > ASTC_HEADER_SIZE && hasValidASTCHeader(bytes))
				return bytes.get(4) + "x" + bytes.get(5);
		}
		catch (e:Dynamic) {}

		return null;
	}

	private static function isKTXFile(path:String):Bool
	{
		try
		{
			if (path == null || !FileSystem.exists(path))
				return false;

			var bytes = File.getBytes(path);
			return bytes != null
				&& bytes.length > KTX_HEADER_SIZE
				&& bytes.get(0) == 0xAB
				&& bytes.get(1) == 0x4B
				&& bytes.get(2) == 0x54
				&& bytes.get(3) == 0x58
				&& bytes.get(4) == 0x20
				&& bytes.get(5) == 0x31
				&& bytes.get(6) == 0x31
				&& bytes.get(7) == 0xBB
				&& bytes.get(8) == 0x0D
				&& bytes.get(9) == 0x0A
				&& bytes.get(10) == 0x1A
				&& bytes.get(11) == 0x0A;
		}
		catch (e:Dynamic) {}

		return false;
	}

	private static function tryUpgradeLegacyCache(project:HXProject, input:String, output:String, cachedMeta:String):Bool
	{
		if (cachedMeta == null || cachedMeta == "" || System.isNewer(input, output))
			return false;

		var blockSize = getMetaValue(cachedMeta, "block");
		if (blockSize == null || blockSize == "")
			return false;

		if (cachedMeta != getLegacyMeta(project, blockSize))
			return false;

		saveMeta(getMetaPath(output), getMeta(project, input, blockSize));
		return true;
	}

	private static function getMetaValue(meta:String, key:String):String
	{
		if (meta == null)
			return null;

		var prefix = key + "=";
		for (line in meta.split("\n"))
		{
			if (StringTools.startsWith(line, prefix))
				return line.substr(prefix.length);
		}

		return null;
	}

	private static function getMeta(project:HXProject, input:String, blockSize:String):String
	{
		return getCacheHeader(project, input)
			+ "block=" + blockSize
			+ "\n";
	}

	private static function getCacheHeader(project:HXProject, input:String):String
	{
		return "version=2"
			+ "\nsource=" + getSourceSignature(input)
			+ "\nsettings=" + getSettingsSignature(project)
			+ "\n";
	}

	private static function getSourceSignature(input:String):String
	{
		try
		{
			var stat = FileSystem.stat(input);
			return normalize(input) + "|" + stat.size + "|" + Std.int(stat.mtime.getTime());
		}
		catch (e:Dynamic) {}

		return normalize(input) + "|missing|0";
	}

	private static function getSettingsSignature(project:HXProject):String
	{
		return [
			"block=" + getBlockSize(project),
			"quality=" + getQuality(project),
			"colorprofile=" + getColorProfile(project),
			"container=" + getTextureExtension(project),
			"premultiplyAlpha=" + getPremultiplyAlpha(project),
			"smartBlocks=" + getSmartBlocks(project),
			"detailBlock=" + getDetailBlockSize(project),
			"largeBlock=" + getLargeBlockSize(project),
			"hugeBlock=" + getHugeBlockSize(project),
			"detailMaxSide=" + project.config.getInt("android.astc-detail-max-side", 1024),
			"detailMinSide=" + project.config.getInt("android.astc-detail-min-side", 256),
			"detailAlphaMaxPixels=" + project.config.getInt("android.astc-detail-alpha-max-pixels", 1048576),
			"largePixels=" + project.config.getInt("android.astc-large-pixels", 4194304),
			"hugePixels=" + project.config.getInt("android.astc-huge-pixels", 16777216),
			"largeMaxSide=" + project.config.getInt("android.astc-large-max-side", 2048),
			"hugeMaxSide=" + project.config.getInt("android.astc-huge-max-side", 4096),
			"detailAlphaRatio=" + project.config.getFloat("android.astc-detail-alpha-ratio", 0.08),
			"detailSemiAlphaRatio=" + project.config.getFloat("android.astc-detail-semi-alpha-ratio", 0.01)
		].join("|");
	}

	private static function getLegacyMeta(project:HXProject, blockSize:String):String
	{
		return "block=" + blockSize
			+ "\nquality=" + getQuality(project)
			+ "\ncolorprofile=" + getColorProfile(project)
			+ "\npremultiplyAlpha=" + getPremultiplyAlpha(project)
			+ "\nsmartBlocks=" + getSmartBlocks(project)
			+ "\nstrict=" + getStrict(project)
			+ "\n";
	}

	private static function getMetaPath(output:String):String
	{
		return output + ".meta";
	}

	/**
		Meta files are only build-cache sidecars; a failed write (for example
		when the path exceeds the Windows MAX_PATH limit) must not abort the
		build. The texture simply won't be cached and gets recompressed next time.
	**/
	private static function saveMeta(path:String, meta:String):Void
	{
		try
		{
			File.saveContent(path, meta);
		}
		catch (e:Dynamic)
		{
			Log.warn("Could not write ASTC meta file (cache disabled for this texture): " + path);
		}
	}

	private static function sanitize(value:String, fallback:String):String
	{
		if (value == null)
			return fallback;
		value = StringTools.trim(value);
		return value == "" ? fallback : value;
	}

	private static function prepareInputPNG(project:HXProject, input:String, output:String):String
	{
		if (!getPremultiplyAlpha(project))
			return input;

		var temp = output + ".premul.png";
		if (FileSystem.exists(temp) && !System.isNewer(input, temp))
			return temp;

		try
		{
			var image = Image.fromFile(input);
			if (image == null || image.buffer == null || image.buffer.data == null)
				return input;

			image.format = PixelFormat.RGBA32;
			if (image.premultiplied)
				image.premultiplied = false;

			var data = image.buffer.data;
			var pixels = image.width * image.height;
			for (i in 0...pixels)
			{
				var offset = i * 4;
				var alpha = data[offset + 3];
				if (alpha <= 0)
				{
					data[offset] = 0;
					data[offset + 1] = 0;
					data[offset + 2] = 0;
				}
				else if (alpha < 255)
				{
					data[offset] = Std.int((data[offset] * alpha + 127) / 255);
					data[offset + 1] = Std.int((data[offset + 1] * alpha + 127) / 255);
					data[offset + 2] = Std.int((data[offset + 2] * alpha + 127) / 255);
				}
			}

			image.buffer.premultiplied = false;
			var encoded = image.encode(ImageFileFormat.PNG);
			if (encoded == null || encoded.length == 0)
				return input;

			System.mkdir(Path.directory(temp));
			File.saveBytes(temp, encoded);
			return temp;
		}
		catch (e:Dynamic)
		{
			Log.warn("ASTC premultiply alpha preprocess failed: " + input + " (" + e + ")");
			return input;
		}
	}

	private static function cleanupPreparedInput(source:String, original:String):Void
	{
		if (source == null || source == "" || source == original)
			return;

		if (!StringTools.endsWith(source.toLowerCase(), ".premul.png"))
			return;

		try
		{
			if (FileSystem.exists(source))
				FileSystem.deleteFile(source);
		}
		catch (e:Dynamic) {}
	}

	private static function analyzeInput(input:String):ASTCImageInfo
	{
		var info = new ASTCImageInfo();
		try
		{
			var image = Image.fromFile(input);
			if (image == null || image.buffer == null || image.buffer.data == null)
				return info;

			image.format = PixelFormat.RGBA32;
			var data = image.buffer.data;
			var pixels = image.width * image.height;
			if (pixels <= 0)
				return info;

			info.width = image.width;
			info.height = image.height;
			info.pixels = pixels;

			var transparent = 0;
			var semiTransparent = 0;
			for (i in 0...pixels)
			{
				var alpha = data[(i * 4) + 3];
				if (alpha <= 8)
					transparent++;
				else if (alpha < 248)
					semiTransparent++;
			}

			info.transparentRatio = transparent / pixels;
			info.semiTransparentRatio = semiTransparent / pixels;
		}
		catch (e:Dynamic) {}
		return info;
	}

	private static function getEffectiveBlockSize(project:HXProject, input:String, info:ASTCImageInfo):String
	{
		var baseBlock = getBlockSize(project);
		if (!getSmartBlocks(project))
			return baseBlock;

		var detailBlock = getDetailBlockSize(project);
		if (baseBlock == detailBlock || info == null || info.width <= 0 || info.height <= 0)
			return baseBlock;

		var path = normalize(input).toLowerCase();
		var maxSide = Std.int(Math.max(info.width, info.height));
		var minSide = Std.int(Math.min(info.width, info.height));
		var detailMaxSide = project.config.getInt("android.astc-detail-max-side", 1024);
		var detailMinSide = project.config.getInt("android.astc-detail-min-side", 256);
		var detailAlphaMaxPixels = project.config.getInt("android.astc-detail-alpha-max-pixels", 1048576);
		var largePixels = project.config.getInt("android.astc-large-pixels", 4194304);
		var hugePixels = project.config.getInt("android.astc-huge-pixels", 16777216);
		var largeMaxSide = project.config.getInt("android.astc-large-max-side", 2048);
		var hugeMaxSide = project.config.getInt("android.astc-huge-max-side", 4096);
		var alphaRatio = project.config.getFloat("android.astc-detail-alpha-ratio", 0.08);
		var semiAlphaRatio = project.config.getFloat("android.astc-detail-semi-alpha-ratio", 0.01);

		var sensitivePath = path.indexOf("/ui/") != -1
			|| path.indexOf("/hud") != -1
			|| path.indexOf("/mobile") != -1
			|| path.indexOf("/notes") != -1
			|| path.indexOf("/note") != -1
			|| path.indexOf("/arrow") != -1
			|| path.indexOf("/strum") != -1
			|| path.indexOf("/splash") != -1
			|| path.indexOf("/menu") != -1
			|| path.indexOf("/menus") != -1
			|| path.indexOf("/icon") != -1
			|| path.indexOf("/icons") != -1
			|| path.indexOf("/title") != -1
			|| path.indexOf("/logo") != -1
			|| path.indexOf("/fonts") != -1;

		if (sensitivePath)
			return detailBlock;
		if (info.pixels >= hugePixels || maxSide >= hugeMaxSide)
			return getHugeBlockSize(project);
		if (info.pixels >= largePixels || maxSide >= largeMaxSide)
			return getLargeBlockSize(project);
		if (maxSide <= detailMaxSide)
			return detailBlock;
		if (minSide <= detailMinSide)
			return detailBlock;
		if (info.pixels <= detailAlphaMaxPixels && (info.transparentRatio >= alphaRatio || info.semiTransparentRatio >= semiAlphaRatio))
			return detailBlock;

		return baseBlock;
	}

	private static function wrapASTCAsKTX(rawASTC:String, output:String):Bool
	{
		try
		{
			if (rawASTC == null || output == null || !FileSystem.exists(rawASTC))
				return false;

			var rawBytes = File.getBytes(rawASTC);
			if (rawBytes == null || rawBytes.length <= ASTC_HEADER_SIZE || !hasValidASTCHeader(rawBytes))
			{
				Log.warn("ASTC KTX container failed; invalid ASTC source: " + rawASTC);
				return false;
			}

			var blockX = rawBytes.get(4);
			var blockY = rawBytes.get(5);
			var blockZ = rawBytes.get(6);
			var width = readU24(rawBytes, 7);
			var height = readU24(rawBytes, 10);
			var depth = readU24(rawBytes, 13);
			var internalFormat = getASTCInternalFormat(blockX, blockY);
			if (blockZ != 1 || depth != 1 || width <= 0 || height <= 0 || internalFormat == 0)
			{
				Log.warn("ASTC KTX container failed; unsupported ASTC source: " + rawASTC);
				return false;
			}

			var payloadLength = rawBytes.length - ASTC_HEADER_SIZE;
			var padding = (4 - (payloadLength % 4)) % 4;
			var ktx = Bytes.alloc(KTX_HEADER_SIZE + 4 + payloadLength + padding);
			writeKTXIdentifier(ktx);
			var offset = 12;
			offset = writeU32LE(ktx, offset, 0x04030201); // endianness
			offset = writeU32LE(ktx, offset, 0); // glType
			offset = writeU32LE(ktx, offset, 1); // glTypeSize
			offset = writeU32LE(ktx, offset, 0); // glFormat
			offset = writeU32LE(ktx, offset, internalFormat);
			offset = writeU32LE(ktx, offset, 0x1908); // GL_RGBA
			offset = writeU32LE(ktx, offset, width);
			offset = writeU32LE(ktx, offset, height);
			offset = writeU32LE(ktx, offset, 0); // pixelDepth
			offset = writeU32LE(ktx, offset, 0); // array elements
			offset = writeU32LE(ktx, offset, 1); // faces
			offset = writeU32LE(ktx, offset, 1); // mip levels
			offset = writeU32LE(ktx, offset, 0); // key/value bytes
			writeU32LE(ktx, KTX_HEADER_SIZE, payloadLength);
			ktx.blit(KTX_HEADER_SIZE + 4, rawBytes, ASTC_HEADER_SIZE, payloadLength);

			System.mkdir(Path.directory(output));
			if (FileSystem.exists(output))
				FileSystem.deleteFile(output);
			File.saveBytes(output, ktx);
			return FileSystem.exists(output);
		}
		catch (e:Dynamic)
		{
			Log.warn("ASTC KTX container failed: " + rawASTC + " (" + e + ")");
			return false;
		}
	}

	private static inline function hasValidASTCHeader(bytes:Bytes):Bool
	{
		return bytes.get(0) == 0x13
			&& bytes.get(1) == 0xAB
			&& bytes.get(2) == 0xA1
			&& bytes.get(3) == 0x5C;
	}

	private static inline function readU24(bytes:Bytes, offset:Int):Int
	{
		return bytes.get(offset) | (bytes.get(offset + 1) << 8) | (bytes.get(offset + 2) << 16);
	}

	private static function getASTCInternalFormat(blockX:Int, blockY:Int):Int
	{
		return switch ('$blockX' + 'x' + '$blockY') {
			case "4x4": 0x93B0;
			case "5x4": 0x93B1;
			case "5x5": 0x93B2;
			case "6x5": 0x93B3;
			case "6x6": 0x93B4;
			case "8x5": 0x93B5;
			case "8x6": 0x93B6;
			case "8x8": 0x93B7;
			case "10x5": 0x93B8;
			case "10x6": 0x93B9;
			case "10x8": 0x93BA;
			case "10x10": 0x93BB;
			case "12x10": 0x93BC;
			case "12x12": 0x93BD;
			default: 0;
		}
	}

	private static function writeKTXIdentifier(bytes:Bytes):Void
	{
		var id = [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A];
		for (i in 0...id.length)
			bytes.set(i, id[i]);
	}

	private static inline function writeU32LE(bytes:Bytes, offset:Int, value:Int):Int
	{
		bytes.set(offset, value & 0xFF);
		bytes.set(offset + 1, (value >> 8) & 0xFF);
		bytes.set(offset + 2, (value >> 16) & 0xFF);
		bytes.set(offset + 3, (value >> 24) & 0xFF);
		return offset + 4;
	}

	private static function compressWithAstcenc(project:HXProject, encoder:String, input:String, output:String, blockSize:String):Bool
	{
		var profile = "-" + getColorProfile(project);
		var quality = getQuality(project);
		if (!StringTools.startsWith(quality, "-"))
			quality = "-" + quality;

		ensureExecutable(encoder);
		var code = System.runCommand("", encoder, [profile, input, output, blockSize, quality], true, true);
		return code == 0;
	}

	private static function compressWithAstcCompressor(project:HXProject, input:String, output:String, blockSize:String):Bool
	{
		if (!hasAstcCompressor())
			return false;

		var outputRoot = getCompressorOutputRoot(input, output);
		var code = Haxelib.runCommand("", [
			"run",
			"astc-compressor",
			"compress",
			"-i",
			input,
			"-blocksize",
			blockSize,
			"-quality",
			getQuality(project),
			"-colorprofile",
			getColorProfile(project),
			"-o",
			outputRoot
		], true, true);

		if (code != 0)
			return false;

		var generated = findGeneratedAstc(outputRoot, input, output);
		if (!FileSystem.exists(output) && generated != null && FileSystem.exists(generated))
		{
			try
			{
				System.mkdir(Path.directory(output));
				if (FileSystem.exists(output))
					FileSystem.deleteFile(output);
				FileSystem.rename(generated, output);
			}
			catch (e:Dynamic) {}
		}

		return FileSystem.exists(output);
	}

	private static function getCompressorOutputRoot(input:String, output:String):String
	{
		var normalizedOutput = normalize(output);
		var normalizedInputAstc = normalize(replaceExtension(input, "astc"));

		if (StringTools.startsWith(normalizedInputAstc, "./"))
			normalizedInputAstc = normalizedInputAstc.substr(2);

		if (StringTools.endsWith(normalizedOutput, normalizedInputAstc))
		{
			var root = normalizedOutput.substr(0, normalizedOutput.length - normalizedInputAstc.length);
			if (StringTools.endsWith(root, "/"))
				root = root.substr(0, root.length - 1);
			if (root != "")
				return root;
		}

		return Path.directory(output);
	}

	private static function findGeneratedAstc(searchRoot:String, input:String, output:String):String
	{
		if (FileSystem.exists(output))
			return output;

		var normalizedInputAstc = normalize(replaceExtension(input, "astc"));
		if (StringTools.startsWith(normalizedInputAstc, "./"))
			normalizedInputAstc = normalizedInputAstc.substr(2);

		var exact = Path.combine(searchRoot, normalizedInputAstc);
		if (FileSystem.exists(exact))
			return exact;

		return findGeneratedAstcRecursive(searchRoot, normalizedInputAstc);
	}

	private static function findGeneratedAstcRecursive(directory:String, suffix:String):String
	{
		if (directory == null || directory == "" || !FileSystem.exists(directory) || !FileSystem.isDirectory(directory))
			return null;

		for (file in FileSystem.readDirectory(directory))
		{
			var path = Path.combine(directory, file);
			if (FileSystem.isDirectory(path))
			{
				var found = findGeneratedAstcRecursive(path, suffix);
				if (found != null)
					return found;
			}
			else
			{
				var normalized = normalize(path);
				if (StringTools.endsWith(normalized, suffix))
					return path;
			}
		}

		return null;
	}

	private static function replaceExtension(path:String, extension:String):String
	{
		if (path == null || path == "")
			return path;
		return Path.withoutExtension(path) + "." + extension;
	}

	private static function normalize(path:String):String
	{
		return StringTools.replace(Path.standardize(path), "\\", "/");
	}

	private static function hasAstcCompressor():Bool
	{
		if (compressorAvailable != null)
			return compressorAvailable;

		var output = Haxelib.runProcess("", ["path", "astc-compressor"], true, true, true);
		compressorAvailable = output != null && output.indexOf("Error:") == -1 && StringTools.trim(output) != "";
		return compressorAvailable;
	}

	private static function hasEncoder():Bool
	{
		var encoder = getDirectEncoder();
		return (encoder != null && encoder != "") || hasAstcCompressor();
	}

	private static function getDirectEncoder():String
	{
		if (checkedEncoder)
			return encoderPath;

		checkedEncoder = true;
		encoderPath = sanitize(Sys.getEnv("ASTC_ENCODER"), null);
		if (encoderPath != null && FileSystem.exists(encoderPath))
		{
			ensureExecutable(encoderPath);
			return encoderPath;
		}

		encoderPath = findBundledAstcCompressorEncoder();
		if (encoderPath != null && encoderPath != "")
			return encoderPath;

		var pathEnv = Sys.getEnv("PATH");
		if (pathEnv == null)
			return null;

		var separator = Sys.systemName() == "Windows" ? ";" : ":";
		var names = getEncoderNames();
		for (dir in pathEnv.split(separator))
		{
			dir = StringTools.trim(dir);
			if (dir == "")
				continue;

			for (name in names)
			{
				var candidate = Path.combine(dir, name);
				if (FileSystem.exists(candidate))
				{
					encoderPath = candidate;
					return encoderPath;
				}
			}
		}

		return null;
	}

	private static function findBundledAstcCompressorEncoder():String
	{
		var output = Haxelib.runProcess("", ["path", "astc-compressor"], true, true, true);
		if (output == null || output.indexOf("Error:") != -1)
			return null;

		var pluginDirs = switch (Sys.systemName())
		{
			case "Windows": ["plugins/Windows/x64", "plugins/Windows/x86", ""];
			case "Mac": ["plugins/macOS", ""];
			default: ["plugins/Linux/x64", "plugins/Linux", ""];
		}
		for (line in output.split("\n"))
		{
			var root = StringTools.trim(line);
			if (root == "" || StringTools.startsWith(root, "-") || StringTools.startsWith(root, "--"))
				continue;

			root = normalize(root);
			if (!FileSystem.exists(root))
				continue;

			for (pluginDir in pluginDirs)
			{
				var dir = pluginDir == "" ? root : Path.combine(root, pluginDir);
				// haxelib may strip executable permissions from bundled binaries,
				// so restore them for every encoder in the directory
				for (name in getEncoderNames())
				{
					var binary = Path.combine(dir, name);
					if (FileSystem.exists(binary))
						ensureExecutable(binary);
				}
				for (name in getEncoderNames())
				{
					var candidate = Path.combine(dir, name);
					if (FileSystem.exists(candidate))
						return candidate;
				}
			}
		}

		return null;
	}

	private static function getEncoderNames():Array<String>
	{
		if (Sys.systemName() == "Windows")
			return ["astcenc-avx2.exe", "astcenc-sse4.1.exe", "astcenc-sse2.exe", "astcenc.exe"];
		return ["astcenc-avx2", "astcenc-sse4.1", "astcenc-sse2", "astcenc"];
	}

	private static function ensureExecutable(path:String):Void
	{
		if (path == null || path == "" || Sys.systemName() == "Windows")
			return;

		try
		{
			Sys.command("chmod", ["+x", path]);
		}
		catch (e:Dynamic) {}
	}

	private static function warnMissingEncoder():Void
	{
		if (missingWarned)
			return;
		missingWarned = true;
		Log.warn("ASTC conversion skipped. Install `astc-compressor` or set ASTC_ENCODER to an astcenc executable.");
	}
}

private class ASTCImageInfo
{
	public var width:Int = 0;
	public var height:Int = 0;
	public var pixels:Int = 0;
	public var transparentRatio:Float = 0;
	public var semiTransparentRatio:Float = 0;

	public function new() {}
}
