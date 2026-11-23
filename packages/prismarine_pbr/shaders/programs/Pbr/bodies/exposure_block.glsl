// The block of the auto exposure.
uniform Exposure {
  // x the lowest log2 luminance of the histogram, y one over its range,
  // z the time step in seconds, w 1 to take the target at once
  vec4 params;
  // x the compensation in EV, y and z the limits of the adapted log2
  // luminance, w the speed towards a brighter scene
  vec4 adapt;
  // x the speed towards a darker scene, y and z the size of the image
  vec4 size;
} cb0;
