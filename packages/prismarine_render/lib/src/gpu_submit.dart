/// Receives the number of each command buffer that the runner submits,
/// before the submit. The numbers count from 1 in the order of the submits.
/// The GPU pass log of `prismarine_debug` takes it.
void Function(int id)? onGpuSubmit;

int _submits = 0;

/// Counts a submit of the runner and passes its number to [onGpuSubmit].
void gpuSubmitted() {
  _submits++;
  onGpuSubmit?.call(_submits);
}
