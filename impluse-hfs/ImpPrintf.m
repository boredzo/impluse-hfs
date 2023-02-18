//
//  ImpPrintf.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-01.
//

#import "ImpPrintf.h"

static bool curMuffled = false;

bool ImpSetPrintfMuffle(bool newMuffled) {
	bool const oldMuffled = curMuffled;
	curMuffled = newMuffled;
	return oldMuffled;
}

int ImpPrintf(NSString *_Nonnull const fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *_Nonnull const msg = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	return printf("%s\n", msg.UTF8String);
}
