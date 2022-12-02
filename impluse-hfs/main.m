//
//  main.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>
#import <sysexits.h>

#import "ImpHFSToHFSPlusConverter.h"

static void usage(char const *_Nullable const argv0) {
	printf("usage: %s hfs-device hfsplus-device\n", argv0 ?: "impluse");
	printf("The two paths must not be the same. The contents of hfs-device will be copied to hfsplus-device. This may take some time.\n");
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		NSEnumerator <NSString *> *_Nonnull const argsEnum = [[NSProcessInfo processInfo].arguments objectEnumerator];
		[argsEnum nextObject];
		NSString *_Nonnull const srcDevPath = [argsEnum nextObject];
		NSString *_Nonnull const dstDevPath = [argsEnum nextObject];
		if (! (srcDevPath != nil && dstDevPath != nil)) {
			usage(argv[0]);
			return EX_USAGE;
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
			return EXIT_FAILURE;
		}
	}
	return EXIT_SUCCESS;
}
