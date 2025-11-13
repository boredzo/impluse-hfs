//
//  main.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>
#import <sysexits.h>

#import "ImpTextEncodingConverter.h"
#import "ImpHFSToHFSPlusConverter.h"
#import "ImpDefragmentingHFSToHFSPlusConverter.h"
#import "ImpHFSExtractor.h"
#import "ImpHFSArchiver.h"
#import "ImpHFSLister.h"
#import "ImpHFSAnalyzer.h"

@interface Impluse : NSObject

@property(copy) NSString *argv0;
@property int status;

- (void) printUsageToFile:(FILE *_Nonnull const)outputFile;
- (void) printArchiveUsage:(FILE *_Nonnull const)outputFile goryDetails:(bool const)showDetailedHelp;
- (void) unrecognizedSubcommand:(NSString *_Nonnull const)subcommand;

- (void) help:(NSEnumerator <NSString *> *_Nonnull const)argsEnum;
- (void) list:(NSEnumerator <NSString *> *_Nonnull const)argsEnum;
- (void) convert:(NSEnumerator <NSString *> *_Nonnull const)argsEnum;
- (void) extract:(NSEnumerator <NSString *> *_Nonnull const)argsEnum;

@end

int main(int argc, const char * argv[]) {
	int status = EXIT_SUCCESS;
	@autoreleasepool {
		NSEnumerator <NSString *> *_Nonnull const argsEnum = [[NSProcessInfo processInfo].arguments objectEnumerator];

		Impluse *_Nonnull const impluse = [Impluse new];
		impluse.argv0 = [argsEnum nextObject];

		NSString *_Nonnull const subcommand = [argsEnum nextObject];
		SEL _Nonnull const subcmdSelector = NSSelectorFromString([subcommand stringByAppendingString:@":"]);
		if ([impluse respondsToSelector:subcmdSelector]) {
			//ARC warns because we could use performSelector:withObject: to call -release or something. We're not doing that, so take out a license to use dynamic dispatch without complaint.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
			[impluse performSelector:subcmdSelector withObject:argsEnum];
#pragma clang diagnostic pop
		} else {
			[impluse unrecognizedSubcommand:subcommand];
		}

		status = impluse.status;
	}
	return status;
}

@implementation Impluse

- (void) printUsageToFile:(FILE *_Nonnull const)outputFile {
	fprintf(outputFile, "usage: %s list [--paths] hfs-device\n", self.argv0.UTF8String ?: "impluse");
	fprintf(outputFile, "Recursively lists the entire contents of a volume, starting from its root directory. With --paths, each item is listed as its full absolute path, which you can pass to extract. Otherwise, you get a more-readable indented listing.\n");
	fprintf(outputFile, "\n");

	fprintf(outputFile, "usage: %s convert hfs-device hfsplus-device\n", self.argv0.UTF8String ?: "impluse");
	fprintf(outputFile, "The two paths must not be the same. The contents of hfs-device will be copied to hfsplus-device. This may take some time.\n");
	fprintf(outputFile, "\n");

	fprintf(outputFile, "usage: %s extract hfs-device [name-or-path] [destination]\n", self.argv0.UTF8String ?: "impluse");
	fprintf(outputFile, "If name-or-path is a single name: Attempt to find a file or folder uniquely bearing that name. If there are multiple matches, list their paths and then exit without extracting anything; otherwise, extract that file or folder.\n");
	fprintf(outputFile, "If name-or-path is an HFS path (like “Macintosh HD:Applications:ResEdit”), extracts that file or folder specifically.\n");
	fprintf(outputFile, "If name-or-path is missing (i.e., there are no arguments after the source device) or is a single colon (“:”), extracts the entire volume.\n");
	fprintf(outputFile, "If destination is absent and name-or-path is a single name, the copy will be created in the current directory. If name-or-path is a full HFS path, the extraction will recreate the folder hierarchy down to that file, starting by creating a folder named for the volume in the current directory.\n");
	fprintf(outputFile, "If destination is a path that does end in a slash, it is treated as the location where the copy should be created, instead of the working directory, and the behavior is otherwise the same as if no destination had been indicated.\n");
	fprintf(outputFile, "If destination is a path that does not end in a slash, it is treated as the location and name where the copy should be created—i.e., the copy will be renamed to the destination path's name if it's different. (If the name-or-path is a full path, the folder hierarchy is not recreated; the indicated file or folder is created at the destination path without any of its containing folders from the source volume.)\n");
	fprintf(outputFile, "\n");

	[self printArchiveUsage:outputFile goryDetails:false];
}
- (void) printArchiveUsage:(FILE *_Nonnull const)outputFile goryDetails:(bool const)showDetailedHelp {
	fprintf(outputFile, "usage: %s archive "
		"[--size size-spec] "
		"[--srcdir source-path|--source-folder source-path] "
//		"[--partition-scheme none] "
		"[--file-system|--filesystem|--fs hfs] "
		"[--label volume-name] "
		"[--encoding encoding-spec] "
//		"[--boot-blocks bb-path] "
		"[-o|--output-path output-path] "
		"[source-paths] "
		"hfs-device\n", self.argv0.UTF8String ?: "impluse");
	fprintf(outputFile, "Create a new HFS volume on a given device (or in a regular file, which will be created if the path does not exist).\n");

	if (! showDetailedHelp) {
		return;
	}

	fprintf(outputFile, "\n");
	fprintf(outputFile, "At least one source item path (including --srcdir) or --size must be provided.\n");
	fprintf(outputFile, "- If source items are given but no --size, then the volume will be only as big as it needs to be to hold those items.\n");
	fprintf(outputFile, "- If --size is given but no source items, then an empty volume of that size will be created.\n");
	fprintf(outputFile, "- If source items and a --size are given, then the volume will be of that size, and creation will fail if the items won't fit.\n");
	fprintf(outputFile, "size-spec can be any whole number followed by nothing, B, S, K, M, G, or T. No suffix or B means bytes. S means sectors (0x200-byte blocks). The volume's size spans from the boot blocks to the alternate volume header, so an empty volume of X size will have less than X in free space.\n");
	fprintf(outputFile, "\n");
	fprintf(outputFile, "Certain words can be used as size-specs:\n");
	fprintf(outputFile, "- hdfloppy: 1440K (1.4 MB, for an FDHD/SuperDrive)\n");
	fprintf(outputFile, "- hd20: 20M (more specifically, 40392S)\n");
	fprintf(outputFile, "- floppy: Smallest of 400K, 800K, hdfloppy, or hd20 that will fit the contents\n");
	fprintf(outputFile, "- hd20sc: 20M (more specifically, 41004S)\n");
	fprintf(outputFile, "- hd40sc: 40M (more specifically, 84294S)\n");
	fprintf(outputFile, "- hd80sc: 80M (more specifically, 156370S)\n");
	fprintf(outputFile, "\n");
	fprintf(outputFile, "Options:\n");
	fprintf(outputFile, "- --source-folder (or --srcdir): Populate the volume with the folder's contents. (As opposed to specifying a folder as a source item without --srcdir; a folder so named is added *inside* the volume.) Additional items can still be specified without option flags; they will be added inside the volume root, alongside the contents of this folder.\n");
	fprintf(outputFile, "- --output-path (or -o): Path to the file to write the new volume to. If this is used, then all arguments not adorned with an option flag are taken as source item paths.\n");
	fprintf(outputFile, "- --label: Specify a volume name. Without --label: If you use --srcdir, the default name is the name of that folder. If not, but a single item is specified, then that item's name is the default volume name. Otherwise, the default volume name is implementation-defined.\n");
	fprintf(outputFile, "- --file-system: Selects what kind of file-system the new volume will contain. Currently, the only option is HFS. File-system names are case-insensitive.\n");
//	fprintf(outputFile, "- --partition-scheme: Selects a type of partition map to wrap the volume in. “none” is the default and does not wrap the volume in a partition map. “anticipate” subtracts 64S from the volume size (so that the created volume can be transplanted using dd into an existing partition map, such as one created with pdisk or on a classic Mac).\n");
	fprintf(outputFile, "- --encoding: Specify an encoding to use to encode names (of files and folders, plus the volume label). This encoding will be tried first, before others are tried as fallback.\n");
//	fprintf(outputFile, "- --boot-blocks: Override the default values in the first block of the boot blocks. This can be either a 0x200-byte file containing raw data to put in the boot blocks, or a plist file containing a dictionary that specifies the fields' values using their names as defined by Inside Macintosh.\n");
	fprintf(outputFile, "\n");
	fprintf(outputFile, "NOTE: HFS had much lower limits for certain things than modern file-systems do, and does not have features that were added in HFS Plus. Difficulties you may encounter when archiving to HFS include:\n");
	fprintf(outputFile, "- Volume names are limited to 27 characters (or, more precisely, bytes).\n");
	fprintf(outputFile, "- File and folder names are limited to 31 characters (or, more precisely, bytes).\n");
	fprintf(outputFile, "- HFS pre-dated Unicode. Names that are easily representable on a modern system may be difficult or impossible to encode in a meaningful way in HFS. Names that originated on an HFS may not get translated correctly to Unicode by extract or convert, and may not round-trip back to HFS successfully when archiving.\n");
	fprintf(outputFile, "- A single fork can be no more than 2 GiB.\n");
	fprintf(outputFile, "- A single folder can't have more than 32,767 items inside it.\n");
	fprintf(outputFile, "- A single volume is limited to approximately 65,535 blocks of no more than 4 GiB each. It is unlikely that you will ever create a 262 TiB volume, but if you ever want to supply more data than that to an HFS-only Mac, you will need to create multiple volumes.\n");
	fprintf(outputFile, "- The span of representable dates runs until 2040-02-06T06:28:15 local time. (This also affects HFS Plus, although that uses GMT.) Years after that cannot be represented in the HFS (and HFS Plus) date format.\n");
	fprintf(outputFile, "- UNIX owner, group, and modes do not exist in HFS.\n");
	fprintf(outputFile, "- Stored extended attributes cannot be translated to HFS and will be lost. (Note that certain extended attributes are synthetic, exposed by API but not stored in the volume; because these attributes are not stored as attributes, and represent metadata that HFS can store by other means, that metadata should get stored on the HFS volume successfully.)\n");
	fprintf(outputFile, "- Hard links will become separate files. Disk usage will increase as a result.\n");
	fprintf(outputFile, "- Symbolic links are currently dereferenced and stored as regular files. THIS MAY CHANGE in a future version.\n");
	fprintf(outputFile, "- Bookmark files (modern alias files) are currently stored as regular files with their contents unchanged (and therefore useless on pre-Snow-Leopard systems). THIS MAY CHANGE in a future version.\n");
	fprintf(outputFile, "- Certain clipping formats have changed. .webloc in particular is a plist format now, which is unlikely to be interpreted successfully by classic Mac OS.\n");
}

- (void) unrecognizedSubcommand:(NSString *_Nonnull const)subcommand {
	fprintf(stderr, "unrecognized subcommand: %s\n", subcommand.UTF8String);
	[self printUsageToFile:stderr];
	self.status = EX_USAGE;
}

- (void) help:(NSEnumerator <NSString *> *_Nonnull const)argsEnum {
	[self printUsageToFile:stdout];
}

#pragma mark Utilities

- (NSString *_Nullable) argument:(NSString *_Nonnull const)arg hasPrefix:(NSString *_Nonnull)optionPrefix {
	if (! [optionPrefix hasSuffix:@"="]) {
		optionPrefix = [optionPrefix stringByAppendingString:@"="];
	}

	if ([arg hasPrefix:optionPrefix]) {
		return [arg substringFromIndex:optionPrefix.length];
	}
	return nil;
}

#pragma mark Verbs

- (void) list:(NSEnumerator <NSString *> *_Nonnull const)argsEnum {
	bool printAbsolutePaths = false;
	bool inventoryApplications = false;
	bool inventoryExtensions = false;
	bool inventoryControlPanels = false;
	bool inventorySharedLibraries = false;
	NSString *_Nullable srcDevPath = nil;
	NSNumber *_Nullable defaultEncoding = nil;
	bool expectsEncoding = false;
	for (NSString *_Nonnull const arg in argsEnum) {
		if (expectsEncoding) {
			defaultEncoding = @([arg integerValue]);
			expectsEncoding = false;
		} else if ((srcDevPath == nil) && [arg isEqualToString:@"--paths"]) {
			printAbsolutePaths = true;
		} else if ([arg isEqualToString:@"--application-inventory"] || [arg isEqualToString:@"--app-inventory"]) {
			inventoryApplications = true;
		} else if ([arg isEqualToString:@"--inventory"]) {
			//TODO: Support --inventory=applications,extensions or some such.
		} else if ([arg isEqualToString:@"--full-inventory"]) {
			inventoryApplications = true;
			inventoryExtensions = true;
			inventoryControlPanels = true;
			inventorySharedLibraries = true;
		} else if ((defaultEncoding == nil) && [arg hasPrefix:@"--encoding"]) {
			if ([arg hasPrefix:@"--encoding="]) {
				//--encoding=42
				defaultEncoding = @([[arg substringFromIndex:@"--encoding=".length] integerValue]);
			} else {
				//--encoding 42
				expectsEncoding = true;
			}
		} else {
			srcDevPath = arg;
		}
	}
	if (srcDevPath == nil) {
		[self printUsageToFile:stderr];
		self.status = EX_USAGE;
		return;
	}

	ImpHFSLister *_Nonnull const lister = [ImpHFSLister new];
	lister.sourceDevice = [NSURL fileURLWithPath:srcDevPath isDirectory:false];
	lister.printAbsolutePaths = printAbsolutePaths;
	lister.inventoryApplications = inventoryApplications;
	lister.inventoryExtensions = inventoryExtensions;
	lister.inventoryControlPanels = inventoryControlPanels;
	lister.inventorySharedLibraries = inventorySharedLibraries;
	if (defaultEncoding != nil) {
		lister.hfsTextEncoding = (TextEncoding)defaultEncoding.integerValue;
	}

	NSError *_Nullable error = nil;
	bool const converted = [lister performInventoryOrReturnError:&error];
	if (! converted) {
		NSLog(@"Failed: %@", error.localizedDescription);
		self.status = EXIT_FAILURE;
	}
}
- (void) convert:(NSEnumerator <NSString *> *_Nonnull const)argsEnum {
	NSNumber *_Nullable defaultEncoding = nil;
	bool copyForkData = true;
	bool expectsEncoding = false;
	NSMutableArray *_Nonnull const devicePaths = [NSMutableArray arrayWithCapacity:2];
	for (NSString *_Nonnull const arg in argsEnum) {
		if (expectsEncoding) {
			defaultEncoding = @([arg integerValue]);
			expectsEncoding = false;
		} else if ((defaultEncoding == nil) && [arg hasPrefix:@"--encoding"]) {
			if ([arg hasPrefix:@"--encoding="]) {
				//--encoding=42
				defaultEncoding = @([[arg substringFromIndex:@"--encoding=".length] integerValue]);
			} else {
				//--encoding 42
				expectsEncoding = true;
			}
		} else if ([arg isEqualToString:@"--no-copy-fork-data"]) {
			copyForkData = false;
		} else if ([arg isEqualToString:@"--copy-fork-data"]) {
			copyForkData = true;
		} else if (devicePaths.count < 2) {
			[devicePaths addObject:arg];
		} else {
			[self printUsageToFile:stderr];
			self.status = EX_USAGE;
			return;
		}
	}
	if (devicePaths.count != 2) {
		[self printUsageToFile:stderr];
		self.status = EX_USAGE;
		return;
	}

	NSString *_Nullable const srcDevPath = devicePaths.firstObject;
	NSString *_Nullable const dstDevPath = devicePaths.lastObject;

	ImpHFSToHFSPlusConverter *_Nonnull const converter = [ImpDefragmentingHFSToHFSPlusConverter new];
	converter.sourceDevice = [NSURL fileURLWithPath:srcDevPath isDirectory:false];
	converter.destinationDevice = [NSURL fileURLWithPath:dstDevPath isDirectory:false];
	if (defaultEncoding != nil) {
		converter.hfsTextEncoding = (TextEncoding)defaultEncoding.integerValue;
	}
	converter.copyForkData = copyForkData;
	converter.conversionProgressUpdateBlock = ^(double progress, NSString * _Nonnull operationDescription) {
		ImpPrintf(@"%u%%: %@", (unsigned)round(100.0 * progress), operationDescription);
	};
	NSError *_Nullable error = nil;
	bool const converted = [converter performConversionOrReturnError:&error];
	if (converted) {
		ImpPrintf(@"Successfully wrote volume to %@", converter.destinationDevice.absoluteURL.path);
	} else {
		NSLog(@"Failed: %@", error.localizedDescription);
		self.status = EXIT_FAILURE;
	}

}
- (void) extract:(NSEnumerator <NSString *> *_Nonnull const)argsEnum {
	NSString *_Nullable const srcDevPath = [argsEnum nextObject];
	if (srcDevPath == nil) {
		[self printUsageToFile:stderr];
		self.status = EX_USAGE;
		return;
	}

	NSString *_Nullable quarryNameOrPath = [argsEnum nextObject];
	if ([quarryNameOrPath isEqualToString:@""] || [quarryNameOrPath isEqualToString:@":"]) {
		//This means “extract the entire volume”, which is the same as nil.
		//nil means no arguments were passed after the source device. If the user wants to extract the whole volume to a specific destination (destinationPath is about to be non-nil), they need to pass something in between the source device or destination; we accept either a single colon or the empty string, though the latter is undocumented (see usage above).
		quarryNameOrPath = nil;
	}

	NSString *_Nullable const destinationPath = [argsEnum nextObject];
	bool const shouldCopyToDestination = (destinationPath != nil) && (![destinationPath hasSuffix:@"/"]);

	ImpHFSExtractor *_Nonnull const extractor = [ImpHFSExtractor new];
	extractor.sourceDevice = [NSURL fileURLWithPath:srcDevPath isDirectory:false];
	extractor.shouldCopyToDestination = shouldCopyToDestination;
	extractor.quarryNameOrPath = quarryNameOrPath;
	extractor.destinationPath = destinationPath;

	extractor.extractionProgressUpdateBlock = ^(double progress, NSString * _Nonnull operationDescription) {
		ImpPrintf(@"%u%%: %@", (unsigned)round(100.0 * progress), operationDescription);
	};
	NSError *_Nullable error = nil;
	bool const extracted = [extractor performExtractionOrReturnError:&error];
	if (! extracted) {
		NSLog(@"Failed: %@", error.localizedDescription);
		self.status = EXIT_FAILURE;
	}
}

- (void) archive:(NSEnumerator <NSString *> *_Nonnull const)argsEnum {
	/*
	"usage: %s archive "
		"[--size size-spec] "
		"[--srcdir source-path|--source-folder source-path] "
//		"[--partition-scheme none] "
		"[--format hfs] "
		"[--label volume-name] "
		"[--encoding encoding-spec] "
//		"[--boot-blocks bb-path] "
		"[source-paths] "
		"hfs-device\n";
	 */

	u_int64_t volumeSizeInBytes = 0;
	NSURL *_Nullable sourceRootFolder = nil;
	NSString *_Nullable volumeFormatString = nil;
	ImpArchiveVolumeFormat _Nullable volumeFormat = ImpArchiveVolumeFormatHFSClassic;
	NSString *_Nullable volumeName = nil;
	NSString *_Nullable encodingString = nil;
	TextEncoding defaultEncoding = kTextEncodingMacRoman;
	NSURL *_Nullable bootBlocksSourceURL = nil;
	NSMutableArray <NSString *> *_Nonnull const paths = [NSMutableArray arrayWithCapacity:2];
	NSURL *_Nullable destinationDevice = nil;

	typedef NS_ENUM(NSUInteger, ImpArchiveOptionExpectation) {
		ImpArchiveOptionExpectNothing,
		ImpArchiveOptionExpectOutputPath,
		ImpArchiveOptionExpectVolumeSize,
		ImpArchiveOptionExpectSourceFolder,
		ImpArchiveOptionExpectVolumeFormat,
		ImpArchiveOptionExpectVolumeLabel,
		ImpArchiveOptionExpectEncoding,
		ImpArchiveOptionExpectBootBlocksPath,
		ImpArchiveOptionExpectTheSpanishInquisition = ' NI!',
	};
	ImpArchiveOptionExpectation expectation = ImpArchiveOptionExpectNothing;
	NSError *_Nullable argumentParseError = nil;
	for (NSString *_Nonnull const arg in argsEnum) {
		NSString *_Nonnull value = arg;
		if (expectation != ImpArchiveOptionExpectNothing) {
		handleArgumentValue:
			switch (expectation) {
				case ImpArchiveOptionExpectOutputPath:
					destinationDevice = [NSURL fileURLWithPath:value isDirectory:false];
					expectation = ImpArchiveOptionExpectNothing;
					break;
				case ImpArchiveOptionExpectVolumeSize:
					volumeSizeInBytes = ImpParseSizeSpecification(value);
					expectation = ImpArchiveOptionExpectNothing;
					break;
				case ImpArchiveOptionExpectSourceFolder:
					sourceRootFolder = [NSURL fileURLWithPath:value isDirectory:true];
					expectation = ImpArchiveOptionExpectNothing;
					break;
				case ImpArchiveOptionExpectVolumeFormat:
					volumeFormatString = value;
					volumeFormat = ImpArchiveVolumeFormatFromString(volumeFormatString);
					expectation = ImpArchiveOptionExpectNothing;
					break;
				case ImpArchiveOptionExpectVolumeLabel:
					volumeName = value;
					expectation = ImpArchiveOptionExpectNothing;
					break;
				case ImpArchiveOptionExpectEncoding:
					encodingString = value;
					defaultEncoding = [ImpTextEncodingConverter parseTextEncodingSpecification:value error:&argumentParseError];
					expectation = ImpArchiveOptionExpectNothing;
					break;
				case ImpArchiveOptionExpectBootBlocksPath:
					bootBlocksSourceURL = [NSURL fileURLWithPath:value isDirectory:false];
					expectation = ImpArchiveOptionExpectNothing;
					break;
				case ImpArchiveOptionExpectNothing:
					[paths addObject:value ?: arg];
			}
		} else {
			if (([arg isEqualToString:@"-o"])) {
				expectation = ImpArchiveOptionExpectOutputPath;
			} else if ((value = [self argument:arg hasPrefix:@"--output-path"])) {
				expectation = ImpArchiveOptionExpectOutputPath;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--encoding"])) {
				expectation = ImpArchiveOptionExpectEncoding;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--srcdir"])) {
				expectation = ImpArchiveOptionExpectSourceFolder;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"-srcdir"])) {
				expectation = ImpArchiveOptionExpectSourceFolder;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--source-folder"])) {
				expectation = ImpArchiveOptionExpectSourceFolder;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"-srcfolder"])) {
				expectation = ImpArchiveOptionExpectSourceFolder;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--file-system"])) {
				expectation = ImpArchiveOptionExpectVolumeFormat;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--filesystem"])) {
				expectation = ImpArchiveOptionExpectVolumeFormat;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--fs"])) {
				expectation = ImpArchiveOptionExpectVolumeFormat;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"-fs"])) {
				expectation = ImpArchiveOptionExpectVolumeFormat;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--label"])) {
				expectation = ImpArchiveOptionExpectVolumeLabel;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--volname"])) {
				expectation = ImpArchiveOptionExpectVolumeLabel;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"-volname"])) {
				expectation = ImpArchiveOptionExpectVolumeLabel;
				goto handleArgumentValue;
			} else if ((value = [self argument:arg hasPrefix:@"--encoding"])) {
				expectation = ImpArchiveOptionExpectEncoding;
				goto handleArgumentValue;
		/*
			} else if ((value = [self argument:arg hasPrefix:@"--boot-blocks"])) {
				expectation = ImpArchiveOptionExpectBootBlocksPath;
				goto handleArgumentValue;
		 */
			} else if ([arg hasPrefix:@"--"]) {
				fprintf(stderr, "unrecognized option: %s\n", arg.UTF8String);
				[self printArchiveUsage:stderr goryDetails:false];
				self.status = EX_USAGE;
			} else {
				goto handleArgumentValue;
			}
		}
	}


	if (paths.count == 0) {
		//There were probably no other options as well, so treat this as a help request.
		[self printArchiveUsage:stdout goryDetails:true];
		self.status = EXIT_SUCCESS;
		return;
	}
	if (paths.count == 1 && (volumeSizeInBytes == 0 && sourceRootFolder == nil)) {
		fprintf(stderr, "error: You must provide at least one item to archive, or use --source-folder, or use --size to create an empty archive of definite size.\n");
		self.status = EX_USAGE;
		return;
	}
	if (volumeFormat == nil) {
		fprintf(stderr, "error: Unknown file-system “%s”. Valid file-systems are HFS and HFS+.\n", volumeFormatString.UTF8String);
		self.status = EX_CONFIG;
		return;
	}
	if (defaultEncoding == kTextEncodingUnknown) {
		fprintf(stderr, "error: Unknown text encoding: %s (error: %s)\n", encodingString.UTF8String, argumentParseError.localizedDescription.UTF8String);
		self.status = EX_CONFIG;
		return;
	}

	ImpTextEncodingConverter *_Nonnull const tec = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:defaultEncoding];
	if (volumeName != nil && [tec lengthOfEncodedString:volumeName] > kHFSMaxVolumeNameChars) {
		fprintf(stderr, "error: Volume label too long. HFS volume names are limited to 27 bytes.\n");
		self.status = EX_CONFIG;
		return;
	}

	NSString *_Nonnull const destinationPath = [paths lastObject];
	destinationDevice = [NSURL fileURLWithPath:destinationPath isDirectory:false];

	[paths removeLastObject];
	NSMutableArray <NSURL *> *_Nonnull const sourceItemURLs = [NSMutableArray arrayWithCapacity:paths.count];
	for (NSString *_Nonnull const path in paths) {
		[sourceItemURLs addObject:[NSURL fileURLWithPath:path]];
	}

	//TEMP
	volumeFormat = ImpArchiveVolumeFormatHFSPlus;

	ImpHFSArchiver *_Nonnull const archiver = [ImpHFSArchiver new];
	archiver.destinationDevice = destinationDevice;
	archiver.volumeSizeInBytes = volumeSizeInBytes;
	archiver.sourceRootFolder = sourceRootFolder;
	archiver.volumeFormat = volumeFormat;
	archiver.volumeName = volumeName;
	archiver.textEncodingConverter = tec;
//	archiver.bootBlocksSourceURL = bootBlocksSourceURL;

	archiver.archivingProgressUpdateBlock = ^(double progress, NSString * _Nonnull operationDescription) {
		ImpPrintf(@"%u%%: %@", (unsigned)round(100.0 * progress), operationDescription);
	};
	NSError *_Nullable error = nil;
	bool const archived = [archiver performArchivingOrReturnError:&error];
	if (! archived) {
		NSLog(@"Failed: %@", error.localizedDescription);
		self.status = EXIT_FAILURE;
	}
}

#pragma mark Debugging commands (not documented)

- (void) analyze:(NSEnumerator <NSString *> *_Nonnull const)argsEnum {
	NSString *_Nullable srcDevPath = nil;
	NSNumber *_Nullable defaultEncoding = nil;
	NSString *_Nullable extentsFilePath = nil;
	bool expectsEncoding = false;
	bool expectsExtentsFilePath = false;
	for (NSString *_Nonnull const arg in argsEnum) {
		if (expectsEncoding) {
			defaultEncoding = @([arg integerValue]);
			expectsEncoding = false;
		} else if (expectsExtentsFilePath) {
			extentsFilePath = arg;
			expectsExtentsFilePath = false;
		} else if ((defaultEncoding == nil) && [arg hasPrefix:@"--encoding"]) {
			if ([arg hasPrefix:@"--encoding="]) {
				//--encoding=42
				defaultEncoding = @([[arg substringFromIndex:@"--encoding=".length] integerValue]);
			} else {
				//--encoding 42
				expectsEncoding = true;
			}
		} else if ((extentsFilePath == nil) && [arg hasPrefix:@"--dump-extents-file"]) {
			if ([arg hasPrefix:@"--dump-extents-file="]) {
				//--dump-extents-file=extents.out
				extentsFilePath = [arg substringFromIndex:@"--dump-extents-file=".length];
			} else {
				//--dump-extents-file extents.out
				expectsExtentsFilePath = true;
			}
		} else if (srcDevPath != nil) {
			[self printUsageToFile:stderr];
			self.status = EX_USAGE;
			return;
		} else {
			srcDevPath = arg;
		}
	}
	if (srcDevPath == nil) {
		[self printUsageToFile:stderr];
		self.status = EX_USAGE;
		return;
	}

	ImpHFSAnalyzer *_Nonnull const analyzer = [ImpHFSAnalyzer new];
	analyzer.sourceDevice = [NSURL fileURLWithPath:srcDevPath isDirectory:false];
	if (defaultEncoding != nil) {
		analyzer.hfsTextEncoding = (TextEncoding)defaultEncoding.integerValue;
	}
	if (extentsFilePath != nil) {
		analyzer.extentsFileTapURL = [NSURL fileURLWithPath:extentsFilePath isDirectory:false];
	}

	NSError *_Nullable error = nil;
	bool const converted = [analyzer performAnalysisOrReturnError:&error];
	if (! converted) {
		NSLog(@"Failed: %@", error.localizedDescription);
		self.status = EXIT_FAILURE;
	}
}

@end
