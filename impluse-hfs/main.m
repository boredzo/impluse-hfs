//
//  main.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>
#import <sysexits.h>

#import "ImpHFSToHFSPlusConverter.h"
#import "ImpHFSExtractor.h"

@interface Impluse : NSObject

@property(copy) NSString *argv0;
@property int status;

- (void) printUsageToFile:(FILE *_Nonnull const)outputFile;
- (void) unrecognizedSubcommand:(NSString *_Nonnull const)subcommand;

- (void) help:(NSEnumerator <NSString *> *_Nonnull const)argsEnum;
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
			[impluse performSelector:subcmdSelector withObject:argsEnum];
		} else {
			[impluse unrecognizedSubcommand:subcommand];
		}

		status = impluse.status;
	}
	return status;
}

@implementation Impluse

- (void) printUsageToFile:(FILE *_Nonnull const)outputFile {
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
}

- (void) unrecognizedSubcommand:(NSString *_Nonnull const)subcommand {
	fprintf(stderr, "unrecognized subcommand: %s\n", subcommand.UTF8String);
	[self printUsageToFile:stderr];
	self.status = EX_USAGE;
}

- (void) help:(NSEnumerator <NSString *> *_Nonnull const)argsEnum {
	[self printUsageToFile:stdout];
}
- (void) convert:(NSEnumerator <NSString *> *_Nonnull const)argsEnum {
	NSString *_Nullable const srcDevPath = [argsEnum nextObject];
	NSString *_Nullable const dstDevPath = [argsEnum nextObject];
	if (! (srcDevPath != nil && dstDevPath != nil)) {
		[self printUsageToFile:stderr];
		self.status = EX_USAGE;
		return;
	}

	ImpHFSToHFSPlusConverter *_Nonnull const converter = [ImpHFSToHFSPlusConverter new];
	converter.sourceDevice = [NSURL fileURLWithPath:srcDevPath isDirectory:false];
	converter.destinationDevice = [NSURL fileURLWithPath:dstDevPath isDirectory:false];
	converter.conversionProgressUpdateBlock = ^(float progress, NSString * _Nonnull operationDescription) {
		ImpPrintf(@"%u%%: %@", (unsigned)round(100.0 * progress), operationDescription);
	};
	NSError *_Nullable error = nil;
	bool const converted = [converter performConversionOrReturnError:&error];
	if (! converted) {
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

	extractor.extractionProgressUpdateBlock = ^(float progress, NSString * _Nonnull operationDescription) {
		ImpPrintf(@"%u%%: %@", (unsigned)round(100.0 * progress), operationDescription);
	};
	NSError *_Nullable error = nil;
	bool const extracted = [extractor performExtractionOrReturnError:&error];
	if (! extracted) {
		NSLog(@"Failed: %@", error.localizedDescription);
		self.status = EXIT_FAILURE;
	}
}

@end
