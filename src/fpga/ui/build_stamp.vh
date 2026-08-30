// Placeholder. tools/podman/build.sh overwrites this in the build copy with
// the first four characters of the commit, so the screen can say which
// bitstream is actually running. Simulation uses the value below.
//
// Nothing writes to this file in the working tree; it is committed so that
// `make test` does not depend on having run `make cart` first.
localparam [15:0] BUILD_STAMP = 16'h0000;
