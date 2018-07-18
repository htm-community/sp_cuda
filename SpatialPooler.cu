#include <stdio.h>

using namespace std;

typedef unsigned int UInt;
typedef float Real;

// Define global constants
const UInt SP_SIZE = 65535;
const UInt IN_SIZE = 131072;
const UInt BLOCK_SIZE = 1024;
const UInt NUM_BLOCKS = SP_SIZE/BLOCK_SIZE;
const UInt IN_BLOCK_SIZE = IN_SIZE/NUM_BLOCKS; // Size of chunk of input processed by a single cuda block
const UInt MAX_CONNECTED = 1024;
const Real IN_DENSITY = 0.5; // Density of input connections

struct args
{
	// Parameters
    UInt inputPitch;
    UInt stimulusThreshold;
    Real potentialPct;
    Real connectedPct;
	Real localAreaDensity;
    Real synPermTrimThreshold;
    Real synPermMax;
    Real synPermConnected;
	Real synPermActiveInc;
	Real synPermInactiveDec;
	Real synPermBelowStimulusInc;
	UInt dutyCyclePeriod;
	Real boostStrength;
	Real minPctOdc;
	bool learn;
	UInt num_connected;

	// Data
	bool* in_dev;
    bool* cols_dev;
	UInt* olaps_dev;
	UInt* pot_dev;
	Real* per_dev;
	Real* boosts_dev;
	Real* odc_dev; // odc serve to maintain same act. freq. for each col. (per block)
	Real* adc_dev; // adc serve to compute boost factors
	UInt* numPot_dev;
	Real* minOdc_dev;

	// Constants
	UInt SP_SIZE;
	UInt MAX_CONNECTED;
	UInt IN_BLOCK_SIZE; // Dims of input chunk for each cuda block

	// Array pitches
	size_t pot_dev_pitch;
	size_t per_dev_pitch;

	// Bookkeeping vars
	UInt iteration_num;
	UInt update_period;

	curandState* dev_states;
};

__global__ void setup_kernel(curandState *state)
{
    int id = threadIdx.x + blockIdx.x*blockDim.x;
    curand_init(727612, id, 0, &state[id]);
}

__device__
inline void random_swap(UInt& a, UInt& b, curandState* state)
{
	// if(curand(state) & 1)
	if(curand_uniform(state) < 0.2)
	{
		UInt temp;
		temp = a;
		a = b;
		b = temp;
	}
}

__global__
void generatePotentialPools(UInt* pot_dev, size_t pot_dev_pitch, UInt num_connected, UInt* input_indeces, curandState* states)
{
	UInt tx = threadIdx.x;
	// UInt BLOCK_SIZE = blockDim.x;
	// No, start with 1 elem per thread
	// UInt elems_per_thread = __ceil((float)IN_BLOCK_SIZE / BLOCK_SIZE);
	curandState localState = states[threadIdx.x + blockIdx.x*blockDim.x];
	extern __shared__ UInt shared[];

	// int i, j;
	// for(i = 0; i < SHARED_SIZE / BLOCK_SIZE; i++)
	// 	j = i*SHARED_SIZE + tx;
	// 	shared[j] = j < IN_BLOCK_SIZE ? input_indeces[j] : shared[j];

	shared[tx] = input_indeces[tx];

    int id = BLOCK_SIZE;	
	float x = 0;
	while(id < IN_BLOCK_SIZE - tx)
	{
		// x = (float) (curand(&localState) % 100) / 100;
		x = curand_uniform(&localState);
		if(x > (float) BLOCK_SIZE / IN_BLOCK_SIZE)
		// if(x < 0.01)
		{
			// No switch, only read
			shared[tx] = input_indeces[tx+id];
		}
		id += BLOCK_SIZE;
	}

	__syncthreads();

	// Do reduction on shared

	if(BLOCK_SIZE >= 512)
	{ 
		if(tx < 256) 
		{ 
			random_swap(shared[tx], shared[tx+256], &localState); 
		} 
		__syncthreads(); 
	}
    if(BLOCK_SIZE >= 256)
   	{ 
		if(tx < 128) 
		{ 
			random_swap(shared[tx], shared[tx+128], &localState); 
		} 
		__syncthreads(); 
	}
    if(BLOCK_SIZE >= 128)
   	{ 
		if(tx < 64) 
		{ 
			random_swap(shared[tx], shared[tx+64], &localState); 
		} 
		__syncthreads(); 
	}

	if(tx < 32) 
    {
        if(BLOCK_SIZE >= 64) 
			random_swap(shared[tx], shared[tx+32], &localState);
        if(BLOCK_SIZE >= 32) 
			random_swap(shared[tx], shared[tx+16], &localState);
        if(BLOCK_SIZE >= 16) 
			random_swap(shared[tx], shared[tx+8], &localState);
        if(BLOCK_SIZE >= 8) 
			random_swap(shared[tx], shared[tx+4], &localState);
        if(BLOCK_SIZE >= 4)
			random_swap(shared[tx], shared[tx+2], &localState);
        if(BLOCK_SIZE >= 2) 
			random_swap(shared[tx], shared[tx+1], &localState);
    }

	__syncthreads();

	// Write to global memory
	
	if(tx < num_connected)
		pot_dev[blockIdx.x*pot_dev_pitch + tx] = shared[tx];
}

__global__
void generatePermanences(Real* per_dev, size_t per_dev_pitch, Real connectedPct, Real synPermConnected, Real synPermMax, curandState* states)
{
	UInt col = blockIdx.x;
	UInt tx = threadIdx.x;
	curandState localState = states[col*blockDim.x + tx];
	// curandState localState = *states;
	bool connected = (Real) curand_uniform(&localState) <= connectedPct;
	per_dev[col*per_dev_pitch + tx] = connected ? synPermConnected + (synPermMax - synPermConnected)*((Real) curand_uniform(&localState)) :
													synPermConnected * (Real)curand_uniform(&localState);
}

__device__
void calculateOverlap(bool* in_dev, bool* in_sh, UInt* pot_dev, Real* per_dev, Real* boosts_dev, UInt* numPot_dev, UInt* olaps_sh, Real threshold, const UInt inBlockSize, const UInt MAX_CONNECTED)
{ 
	int tx = threadIdx.x;
   	int sp_idx = blockDim.x*blockIdx.x + tx; // Global index in the SP
	int num_assnd = (int)(inBlockSize/blockDim.x);
	int in_idx = inBlockSize*blockIdx.x + tx*num_assnd; // Beginning of portion of input assigned to this thread
    olaps_sh[tx] = 0;
	// Let each thread load its part of input to shared memory
	for(int i=0; i < num_assnd; i++)
		in_sh[tx*num_assnd+i] = in_dev[in_idx+i]; 

	__syncthreads();

    for(int i=0; i < numPot_dev[sp_idx]; i++)
    {
		UInt bl_idx = pot_dev[sp_idx*MAX_CONNECTED+i]; // Index of block-specific input
		if(in_sh[bl_idx] && per_dev[sp_idx*MAX_CONNECTED+i] >= threshold)
        	olaps_sh[tx] += boosts_dev[sp_idx+i];
    }
}

__device__
void calculateOverlap(UInt* olaps_sh, bool* in_sh, bool* in_dev, UInt* pot_dev, size_t pot_dev_pitch, Real* per_dev, size_t per_dev_pitch, Real* boosts_dev, Real threshold, UInt numConnected)
{
	// TODO: block sizes should be restricted such that shared memory is never exceeded
	// __shared__ UInt in_sh[IN_BLOCK_SIZE];

	// thread per column, each loads index, then permanence, one after another -> accesses are coalesced
	// accesses to shared memory are not coalesced

	UInt tx = threadIdx.x;
   	UInt sp_idx = blockDim.x*blockIdx.x + tx; // Global index in the SP
	UInt in_block_start = IN_BLOCK_SIZE*blockIdx.x;
	UInt olaps = 0;

	for(int i = 0; i < IN_BLOCK_SIZE - tx; i += blockDim.x)
		in_sh[tx + i] = in_dev[in_block_start + tx + i]; 

	__syncthreads();

    for(int i=0; i < numConnected; i++)
    {
		UInt bl_idx = pot_dev[sp_idx*pot_dev_pitch+i]; // Index of block-specific input
		if(in_sh[bl_idx] && (per_dev[sp_idx*per_dev_pitch+i] >= threshold))
        	olaps += boosts_dev[sp_idx+i];
    }

	__syncthreads();

	olaps_sh[tx] = olaps;
}

__device__
void inhibitColumns(UInt* olaps_sh, bool* cols_dev, Real* active_sh, bool &active, Real sparsity)
{
    int tx = threadIdx.x;
	int numLarger = 0;
	active = false;
	
	for(int i=0; i < blockDim.x; i++)
	{
		if(olaps_sh[i] > olaps_sh[tx]) numLarger++;
	}
	if(numLarger < sparsity*blockDim.x) active = true;

	__syncthreads();

	cols_dev[blockIdx.x*blockDim.x + tx] = active;
	active_sh[tx] = active;
}

__device__
void adaptSynapses(bool* in_dev, UInt* pot_dev, Real* per_dev, Real synPermActiveInc, Real synPermInactiveDec, bool active, const UInt inBlockSize, const UInt MAX_CONNECTED)
{
    int tx = threadIdx.x;
   	int sp_idx = blockDim.x*blockIdx.x + tx;
	if(active)
	{
		for(int i=0; i < MAX_CONNECTED; i++)
    	{
			int in_idx = pot_dev[sp_idx*MAX_CONNECTED+i];
			if(in_dev[inBlockSize*blockIdx.x + in_idx])
				per_dev[sp_idx*MAX_CONNECTED+i] = min(1.0, per_dev[sp_idx*MAX_CONNECTED+i]+synPermActiveInc);
			else
				per_dev[sp_idx*MAX_CONNECTED+i] = max(per_dev[sp_idx*MAX_CONNECTED+i]-synPermInactiveDec, 0.0);
    	}
	}
}

__device__
void updateDutyCycles(Real* odc_dev, Real* adc_dev, UInt* olaps_sh, bool active, UInt iteration_num, UInt dutyCyclePeriod)
{
    int tx = threadIdx.x;

	// Let grow divisor only to a dutyCyclePeriod to not make the update increasingly negligible
	Real period = dutyCyclePeriod > iteration_num ? iteration_num : dutyCyclePeriod;

	odc_dev[blockDim.x*blockIdx.x+tx] = (odc_dev[blockDim.x*blockIdx.x+tx]*(period-1) + (Real)(olaps_sh[tx] > 0)) / period;
	adc_dev[blockDim.x*blockIdx.x+tx] = (odc_dev[blockDim.x*blockIdx.x+tx]*(period-1) + (Real)active) / period;
}

__device__
void averageActivity(Real* active_sh)
{
	Real avg = 0;
	for(int i=0; i < blockDim.x; i++)
	{
		avg += active_sh[i];
	}
	active_sh[threadIdx.x] = avg / (Real)blockDim.x;
}

__device__
void averageActivityReduction(Real* active_sh)
{
	int tx = threadIdx.x;
	UInt BLOCK_SIZE = blockDim.x;
	
	if(BLOCK_SIZE >= 512)
	{ 
		if(tx < 256) 
		{ 
			active_sh[tx] += active_sh[tx+256]; 
		} 
		__syncthreads(); 
	}
    if(BLOCK_SIZE >= 256)
   	{ 
		if(tx < 128) 
		{ 
			active_sh[tx] += active_sh[tx+128]; 
		} 
		__syncthreads(); 
	}
    if(BLOCK_SIZE >= 128)
   	{ 
		if(tx < 64) 
		{ 
			active_sh[tx] += active_sh[tx+64]; 
		} 
		__syncthreads(); 
	}

    if(tx < 32) 
    {
        if(BLOCK_SIZE >= 64) 
			active_sh[tx] += active_sh[tx+32];
        if(BLOCK_SIZE >= 32) 
			active_sh[tx] += active_sh[tx+16];
        if(BLOCK_SIZE >= 16) 
			active_sh[tx] += active_sh[tx+8];
        if(BLOCK_SIZE >= 8) 
			active_sh[tx] += active_sh[tx+4];
        if(BLOCK_SIZE >= 4)
			active_sh[tx] += active_sh[tx+2];
        if(BLOCK_SIZE >= 2) 
			active_sh[tx] += active_sh[tx+1];
    }

	__syncthreads();

	// According to https://devblogs.nvidia.com/using-shared-memory-cuda-cc/, this should result in a broadcast
    active_sh[tx] = active_sh[0] / BLOCK_SIZE;
}

__device__
void updateBoosts(Real* adc_dev, Real* boosts_dev, Real targetDensity, Real boostStrength)
{
    int sp_idx = blockIdx.x*blockDim.x+threadIdx.x;
	boosts_dev[sp_idx] = exp((targetDensity - adc_dev[sp_idx])*boostStrength);
}

__device__
void bumpUpColumnsWithWeakOdc(Real* odc_dev, Real* per_dev, UInt* numPot, Real* minOdc_dev, Real synPermBelowStimulusInc, const UInt MAX_CONNECTED)
{
	int tx = threadIdx.x;
    int sp_idx = blockIdx.x*blockDim.x+tx;

	if(odc_dev[sp_idx] < minOdc_dev[blockIdx.x]) {
		for(int i=0; i<numPot[sp_idx]; i++)
			per_dev[tx*MAX_CONNECTED+i] += synPermBelowStimulusInc;
	}
}

__device__
void updateMinOdc(Real* odc_dev, Real* odc_sh, Real* minOdc_dev, Real minPctOdc, const UInt SP_SIZE)
{
	Real maxOdc = 0;
	for(int i=0; i<SP_SIZE; i++)
		maxOdc = odc_dev[i] > maxOdc ? odc_dev[i] : maxOdc;
	if(threadIdx.x == 0)
		minOdc_dev[blockIdx.x] = minPctOdc * maxOdc;
}

// Lambdas are available in nvcc > 7.5
__device__
void updateMinOdcReduction(Real* odc_dev, Real* odc_sh, Real* minOdc_dev, Real minPctOdc, const UInt SP_SIZE)
{
	int tx = threadIdx.x;
	int sp_idx = blockDim.x*blockIdx.x + threadIdx.x;
	UInt BLOCK_SIZE = blockDim.x;

	odc_sh[tx] = odc_dev[sp_idx];
	
	if(BLOCK_SIZE >= 512)
	{ 
		if(tx < 256) 
		{ 
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+256]); 
		} 
		__syncthreads(); 
	}
    if(BLOCK_SIZE >= 256)
   	{ 
		if(tx < 128) 
		{ 
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+128]); 
		} 
		__syncthreads(); 
	}
    if(BLOCK_SIZE >= 128)
   	{ 
		if(tx < 64) 
		{ 
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+64]); 
		} 
		__syncthreads(); 
	}

    if(tx < 32) 
    {
        if(BLOCK_SIZE >= 64) 
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+32]);
        if(BLOCK_SIZE >= 32) 
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+16]);
        if(BLOCK_SIZE >= 16) 
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+8]);
        if(BLOCK_SIZE >= 8) 
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+4]);
        if(BLOCK_SIZE >= 4)
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+2]);
        if(BLOCK_SIZE >= 2) 
			odc_sh[tx] = max(odc_sh[tx], odc_sh[tx+1]);
    }

	if(threadIdx.x == 0)
		minOdc_dev[blockIdx.x] = minPctOdc * odc_sh[0];
}





__global__
void compute(args* ar_ptr)
{
	// Global memory pointers
    // bool* cols_dev = (bool*) data;
	// bool* in_dev = &cols_dev[SP_SIZE];
	// UInt* pot_dev = (UInt*) &in_dev[IN_SIZE];
	// UInt* numPot_dev = &pot_dev[SP_SIZE*MAX_CONNECTED];
	// Real* per_dev = (Real*) &numPot_dev[SP_SIZE];
	// Real* boosts_dev = &per_dev[SP_SIZE*MAX_CONNECTED];
	// UInt* olaps_dev = (UInt*) &boosts_dev[SP_SIZE*MAX_CONNECTED];
	// Real* odc_dev = (Real*) &olaps_dev[SP_SIZE]; // odc serve to maintain same act. freq. for each col. (per block)
	// Real* adc_dev =  &odc_dev[MAX_CONNECTED*SP_SIZE]; // adc serve to compute boost factors
	// Real* minOdc_dev = &adc_dev[MAX_CONNECTED*SP_SIZE]; // Stores minumum overlap duty cycles per block 

	
	if (blockIdx.x == 0 && threadIdx.x == 0) 
		ar_ptr->iteration_num++;
	
	args ar = *ar_ptr;

	bool active = false;
	Real avg_act = 0;

    extern __shared__ UInt shared[];
	UInt* olaps_sh = &shared[0];
	// Lepsi jako volatile
	Real* active_sh = (Real*)&shared[blockDim.x];
	Real* odc_sh = &active_sh[blockDim.x];
	bool* in_sh = (bool*) &odc_sh[blockDim.x];

	// calculateOverlap(ar.in_dev, in_sh, ar.pot_dev, ar.per_dev, ar.boosts_dev, ar.numPot_dev, olaps_sh, ar.synPermConnected, ar.IN_BLOCK_SIZE, ar.MAX_CONNECTED);

    calculateOverlap(olaps_sh, in_sh, ar.cols_dev, ar.pot_dev, ar.pot_dev_pitch, ar.per_dev, ar.per_dev_pitch, ar.boosts_dev, ar.synPermConnected, ar.num_connected);
	
	__syncthreads();

	inhibitColumns(olaps_sh, ar.cols_dev, active_sh, active, ar.localAreaDensity);
	
	__syncthreads();

	adaptSynapses(ar.cols_dev, ar.pot_dev, ar.per_dev, ar.synPermActiveInc, ar.synPermInactiveDec, active, ar.IN_BLOCK_SIZE, ar.MAX_CONNECTED);

	updateDutyCycles(ar.odc_dev, ar.adc_dev, olaps_sh, active, ar.iteration_num, ar.dutyCyclePeriod);

	averageActivityReduction(active_sh);

	__syncthreads();

	updateBoosts(ar.adc_dev, ar.boosts_dev, avg_act, ar.boostStrength);

	bumpUpColumnsWithWeakOdc(ar.odc_dev, ar.per_dev, ar.numPot_dev, ar.minOdc_dev, ar.synPermBelowStimulusInc, ar.MAX_CONNECTED);

	if(ar.iteration_num % ar.update_period == 0)
		updateMinOdc(ar.odc_dev, ar.odc_dev, ar.minOdc_dev, ar.minPctOdc, ar.SP_SIZE);
}

__global__
void calculateOverlap_wrapper(bool* in_dev, UInt* pot_dev, Real* per_dev, Real* boosts_dev, UInt* numPot_dev, Real threshold, const UInt inBlockSize, const UInt MAX_CONNECTED, UInt* olaps_dev, const UInt SP_SIZE)
{
	extern __shared__ UInt shared[];
	UInt* olaps_sh = &shared[0];
	bool* in_sh = (bool*) &olaps_sh[blockDim.x];

	calculateOverlap(in_dev, in_sh, pot_dev, per_dev, boosts_dev, numPot_dev, olaps_sh, threshold, inBlockSize, MAX_CONNECTED);

	if(blockDim.x*blockIdx.x+threadIdx.x < SP_SIZE)
		olaps_dev[blockDim.x*blockIdx.x+threadIdx.x] = olaps_sh[threadIdx.x];
}


__global__
void inhibitColumns_wrapper(UInt* olaps_dev, bool* cols_dev, Real localAreaDensity, const UInt BLOCK_SIZE)
{
	extern __shared__ UInt shared[];
	UInt* olaps_sh = &shared[0];
	Real* active_sh = (Real*) &olaps_sh[BLOCK_SIZE];

	olaps_sh[threadIdx.x] = olaps_dev[threadIdx.x];

	bool active = false;

	__syncthreads();

	inhibitColumns(olaps_sh, cols_dev, active_sh, active, localAreaDensity);
}

__global__
void adaptSynapses_wrapper(bool* in_dev, UInt* pot_dev, Real* per_dev, Real synPermActiveInc, Real synPermInactiveDec, bool* active_arr, const UInt IN_BLOCK_SIZE, const UInt MAX_CONNECTED, const UInt SP_SIZE)
{
	int sp_idx = blockIdx.x*blockDim.x + threadIdx.x;
	if(sp_idx < SP_SIZE)
	{
		bool active = active_arr[sp_idx];
		adaptSynapses(in_dev, pot_dev, per_dev, synPermActiveInc, synPermInactiveDec, active, IN_BLOCK_SIZE, MAX_CONNECTED);
	}
}

__global__
void averageActivity_wrapper(bool* cols_dev, Real* avg_dev)
{
	int tx = threadIdx.x;

	extern __shared__ UInt shared[];
	Real* active_sh = (Real*) &shared[0];

	active_sh[tx] = (Real) cols_dev[tx];

	averageActivityReduction(active_sh);

	avg_dev[tx] = active_sh[tx];	
}
