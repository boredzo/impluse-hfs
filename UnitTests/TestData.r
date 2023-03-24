data 'STR#' (128, "Test strings") {
	$"0005"
	$"05 416C 7068 61" /*Alpha*/
	$"05 4272 6176 6F" /*Bravo*/
	$"07 4368 6172 6C69 65" /*Charlie*/
	$"05 4465 6C74 61" /*Delta*/
	$"04 4563 686F" /*Echo*/
};

/*'str#' is not a well-known type, but is used here to have two types, and three resources of the second.*/
data 'str#' (129, "More test strings") {
	$"0005"
	$"07 466F 7874 726F 74" /*Foxtrot*/
	$"04 476F 6C66" /*Golf*/
	$"05 486F 7465 6C" /*Hotel*/
	$"05 496E 646961" /*India*/
	$"06 4A75 6C69 6574" /*Juliet*/
};
data 'str#' (130, "More test strings") {
	$"0001"
	$"04 4B69 6C6F" /*Kilo*/
};
data 'str#' (131, "More test strings") {
	$"0000"
};

/*Defined in ResEdit to be 12.3.4 final non-release 56.
 *12: major
 *34: minor (.3) and bug-fix (.4)
 *80: final
 *56: non-release (note: also BCD, though this fact isn't documented)
 */
data 'vers' (128) {
	/*0011 2233 4455 6677 8899 AABB CCDD EEFF*/
	/*000*/
	$"1234 8056 0000 1453 686F 7274 2076 6572"            /* .4ÄV...Short ver */
	/*100*/
	$"7369 6F6E 2073 7472 696E 6729 4C6F 6E67"            /* sion string)Long */
	/*200*/
	$"2076 6572 7369 6F6E 2073 7472 696E 670D"            /*  version string. */
	/*300*/
	$"4974 206A 7573 7420 6B65 6570 7320 676F"            /* It just keeps go */
	/*400*/
	$"696E 6721 21"                                       /* ing!! */
	/*1122 3344 5566 7788 99AA BBCC DDEE FF00*/
	/*45*/
};

