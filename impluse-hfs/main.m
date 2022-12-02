//
//  main.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>
#import <sysexits.h>

#import "ImpHFSToHFSPlusConverter.h"

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
	NSString *_Nonnull const srcDevPath = [argsEnum nextObject];
	NSString *_Nonnull const dstDevPath = [argsEnum nextObject];
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
	//TODO: Write an ImpHFSExtractor that implements at least this feature, similar to how we have ImpHFSToHFSPlusConverter for convert:.
}

@end
