/*
    Author: Thomas Rolinger (tbrolin@cs.umd.edu)
    Date:   12/18/2017
    File:   mttkrp.chpl

    Description:    This is a module file for things related
                    to the MTTKRP.

                    To make things easier, we are only doing
                    3-mode tensors. I'll fill in the code for
                    n-mode tensors some other time.
*/

module MTTKRP {
    use Base;
    use CSF;
    use Args;
    use Assert;
    use Util;
    use MutexPool;
    use Barriers;

    /*****************************
    *
    *   priv_buffer class
    *
    ******************************/
    class priv_buffer {
        var buffer_d : domain(2) = {0..1, 0..1};
        var buffer : [buffer_d] real;
    }

    /*****************************
    *
    *   tree_partition class
    *
    ******************************/
    class tree_part {
        var tree_part_d : domain(1) = 0..1;
        var buf : [tree_part_d] int;
    }

    /*****************************
    *
    *   MTTKRP workspace class
    *
    ******************************/
    class splatt_mttkrp_ws {
        /* How many CSF representations are available */
        var num_csf : int;
        /* Mapping of modes -> CSF representations (which CSF to use) */  
        var mode_csf_map : [NUM_MODES_d] int;
        /* Number of threads to use */
        var num_threads : int;

        /*
            Partitioning information. If the CSF is tiled, we
            distribute tiles to threads. If the CSF is untiled,
            we distribute slices to threads. Partitioning is performed
            on a per-CSF basis, so we have one for each mode (the
            maximum number of CSF). In all cases, we rely on static
            partitioning via chains-on-chains partitioning.
        */
        var tree_d : domain(1) = 0..1;
        var tile_partition : [0..0] int;
        var tree_partition : [tree_d] tree_part;

        /*
            Privatization information: Privatizing a mode replicates the
            output matrix by each thread in order to avoid lock contention.
            This is useful when the tensor mode is short.
        */
        
        /* Marks if a tensor mode is privatized */
        var is_privatized : [NUM_MODES_d] bool;
        /* 
            The buffer used by each thread for privatization.
            privatize_buffer[thread_id] is large enough to process
            the largest privatized mode.
        */
        var privatize_buffer : [0..numThreads_g] priv_buffer;

        /* Time spent on the latest privatized reduction */
        var reduction_time : real;
    }

/*#################################################################################################
#
#   Below are the classes for the various MTTKRP functions, which we need to "pass" into the
#   p_schedule_tiles function. We declare a class for each function, and the only thing within
#   the class is the function, called func. The function within the class will call out to other
#   functions, which are defined further below.
#
####################################################################################################*/

    /*****************************
    *
    *   Functions for MTTKRP-root locked
    *
    ******************************/
    class mttkrp_root_locked {
        //p_csf_mttkrp_root_locked
        proc func(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
        {
            const nmodes = ct.nmodes;
            if nmodes == 3 {
                p_csf_mttkrp_root3_locked(ct, tile_id, mats, m1, mode, thds, partition, tid);
                return;
            }
        }
    }
 
    /*****************************
    *
    *   Functions for MTTKRP-root nolock
    *
    ******************************/
    class mttkrp_root_nolock {
        //p_csf_mttkrp_root_nolock
        proc func(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
        {
            const nmodes = ct.nmodes;
            if nmodes == 3 {
                p_csf_mttkrp_root3_nolock(ct, tile_id, mats, m1, mode, thds, partition, tid);
                return;
            }
        }
    }

    /*****************************
    *
    *   Functions for MTTKRP-leaf locked
    *
    ******************************/
    class mttkrp_leaf_locked {
        // p_mttkrp_leaf_locked
        proc func(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
        {
            const nmodes = ct.nmodes;
            if nmodes == 3 {
                p_csf_mttkrp_leaf3_locked(ct, tile_id, mats, m1, mode, thds, partition, tid);
                return;
            }
        }
    } 

    /*****************************
    *
    *   Functions for MTTKRP-leaf no lock
    *
    ******************************/
    class mttkrp_leaf_nolock {
        // p_csf_mttkrp_leaf_nolock
        proc func(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
        {
            const nmodes = ct.nmodes;
            if nmodes == 3 {
                p_csf_mttkrp_leaf3_nolock(ct, tile_id, mats, m1, mode, thds, partition, tid);
                return;
            }
        } 
    } 

    
    /*****************************
    *
    *   Functions for MTTKRP-internal locked
    *
    ******************************/
    class mttkrp_intl_locked {
        // p_mttkrp_intl_locked
        proc func(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
        {
            const nmodes = ct.nmodes;
            if nmodes == 3 {
                p_csf_mttkrp_intl3_locked(ct, tile_id, mats, m1, mode, thds, partition, tid);   
                return;
            }
        }
    } 

    /*****************************
    *
    *   Functions for MTTKRP-internal no lock
    *
    ******************************/
    class mttkrp_intl_nolock {
        // p_csf_mttkrp_intl_nolock
        proc func(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
        {
            const nmodes = ct.nmodes;
            if nmodes == 3 {
                p_csf_mttkrp_intl3_nolock(ct, tile_id, mats, m1, mode, thds, partition, tid);
                return;
            }
        }
    }   
 
/*#################################################################################################
#
#   Below are the various private functions
#
####################################################################################################*/

    /*****************************
    *
    *   Private Functions
    *
    ******************************/
    private proc p_csf_mttkrp_root3_locked(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
    {
        assert(ct.nmodes == 3);
        const nmodes = ct.nmodes;
        // pointers to 1D chapel arrays
        const ref vals = ct.pt[tile_id].vals;
        const ref sptr = ct.pt[tile_id].fptr[0].subtree;
        const ref fptr = ct.pt[tile_id].fptr[1].subtree;
        const ref sids = ct.pt[tile_id].fids[0].fiber_ids;
        const ref fids = ct.pt[tile_id].fids[1].fiber_ids;
        const ref inds = ct.pt[tile_id].fids[2].fiber_ids;

        // pointers to 2D chapel matrices
        const avals = mats[csf_depth_to_mode(ct,1)].vals_ref;
        const bvals = mats[csf_depth_to_mode(ct,2)].vals_ref;
        const ovals = m1.vals_ref;

        const nfactors = mats[nmodes].J;

        // pointer to 1D chapel array
        const accumF = c_ptrTo(thds[tid].scratch[0].buf);
        
        // write to output
        const writeF = c_ptrTo(thds[tid].scratch[2].buf);
        for r in 0..nfactors-1 {
            writeF[r] = 0.0;
        }

        const nslices = ct.pt[tile_id].nfibs[0];
        const start = partition[tid];
        const stop = partition[tid+1];
        for s in start..stop-1 {
            /* for each fiber in slice */   
            for f in sptr[s]..sptr[s+1]-1 {
                /* first entry of the fiber is used to initialize accumF */
                const jjfirst = fptr[f];
                const vfirst = vals[jjfirst];
                const bv = bvals + (inds[jjfirst] * nfactors);
                for r in 0..nfactors-1 {
                    accumF[r] = vfirst * bv[r];
                }
                /* for each nnz in fiber */
                for jj in fptr[f]+1..fptr[f+1]-1 {
                    const v = vals[jj];
                    const bv = bvals + (inds[jj] * nfactors);
                    for r in 0..nfactors-1 {
                        accumF[r] += v * bv[r];
                    }
                }
                /* scale inner products by row of A and upate to M */
                const av = avals + (fids[f] * nfactors);
                for r in 0..nfactors-1 {
                    writeF[r] += accumF[r] * av[r];
                }
            }
            // checking for sids == NULL
            const fid = if sids[0] == -1 then s else sids[s];
            const mv = ovals + (fid * nfactors);
            
            /* flush to output */
            mutex_set_lock(pool_g, fid, tid);
            for r in 0.. nfactors-1 {
                mv[r] += writeF[r];
                writeF[r] = 0.0;
            }
            mutex_unset_lock(pool_g, fid, tid);
        }
    }

    //***********************************************************************
    private proc p_csf_mttkrp_root3_nolock(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
    {
        assert(ct.nmodes == 3);
        const nmodes = ct.nmodes;
        const ref vals = ct.pt[tile_id].vals;
        const ref sptr = ct.pt[tile_id].fptr[0].subtree;
        const ref fptr = ct.pt[tile_id].fptr[1].subtree;
        const ref sids = ct.pt[tile_id].fids[0].fiber_ids;
        const ref fids = ct.pt[tile_id].fids[1].fiber_ids;
        const ref inds = ct.pt[tile_id].fids[2].fiber_ids;

        // pointers to 2D chapel matrices
        const avals = mats[csf_depth_to_mode(ct,1)].vals_ref;
        const bvals = mats[csf_depth_to_mode(ct,2)].vals_ref;
        const ovals = m1.vals_ref;

        const nfactors = mats[nmodes].J;

        // pointer to 1D chapel array
        const accumF = c_ptrTo(thds[tid].scratch[0].buf);

        // write to output
        const writeF = c_ptrTo(thds[tid].scratch[2].buf);
        for r in 0..nfactors-1 {
            writeF[r] = 0.0;
        }

        const nslices = ct.pt[tile_id].nfibs[0];
        const start = partition[tid];
        const stop = partition[tid+1];
        for s in start..stop-1 {
            const fid = if sids[0] == -1 then s else sids[s];
            const mv = ovals + (fid * nfactors);
            /* for each fiber in slice */
            for f in sptr[s]..sptr[s+1]-1 {
                /* first entry of the fiber is used to initialize accumF */
                const jjfirst = fptr[f];
                const vfirst = vals[jjfirst];
                const bv = bvals + (inds[jjfirst] * nfactors);
                for r in 0..nfactors-1 {
                    accumF[r] = vfirst * bv[r];
                }
                /* for each nnz in fiber */
                for jj in fptr[f]+1..fptr[f+1]-1 {
                    const v = vals[jj];
                    const bv = bvals + (inds[jj] * nfactors);
                    for r in 0..nfactors-1 {
                        accumF[r] += v * bv[r];
                    }
                }
                /* scale inner products by row of A and upate to M */
                const av = avals + (fids[f] * nfactors);
                for r in 0..nfactors-1 {
                    writeF[r] += accumF[r] * av[r];
                }
            }
            /* flush to output */
            for r in 0.. nfactors-1 {
                mv[r] += writeF[r];
                writeF[r] = 0.0;
            }
        }
    }
    
    //***********************************************************************
    private proc p_csf_mttkrp_leaf3_locked(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
    {
        assert(ct.nmodes == 3);
        const nmodes = ct.nmodes;
        const ref vals = ct.pt[tile_id].vals;
        const ref sptr = ct.pt[tile_id].fptr[0].subtree;
        const ref fptr = ct.pt[tile_id].fptr[1].subtree;
        const ref sids = ct.pt[tile_id].fids[0].fiber_ids;
        const ref fids = ct.pt[tile_id].fids[1].fiber_ids;
        const ref inds = ct.pt[tile_id].fids[2].fiber_ids;

        // pointers to 2D chapel matrices
        const avals = mats[csf_depth_to_mode(ct,0)].vals_ref;
        const bvals = mats[csf_depth_to_mode(ct,1)].vals_ref;
        const ovals = m1.vals_ref;
        const nfactors = mats[nmodes].J;

        // pointer to 1D chapel array
        const accumF = c_ptrTo(thds[tid].scratch[0].buf);

        const nslices = ct.pt[tile_id].nfibs[0];
        const start = partition[tid];
        const stop = partition[tid+1];

        for s in start..stop-1 {
            const fid = if sids[0] == -1 then s else sids[s];
            /* root row */
            const rv = avals + (fid * nfactors);
            /* for each fiber in slice */
            for f in sptr[s]..sptr[s+1]-1 {
                /* fill fiber with hada */
                const av = bvals + (fids[f] * nfactors);
                for r in 0..nfactors-1 {
                    accumF[r] = rv[r] * av[r];
                }
                /* for each nnz in fiber, scale with hada and write to ovals */
                for jj in fptr[f]..fptr[f+1]-1 {
                    const v = vals[jj];
                    const ov = ovals + (inds[jj] * nfactors);
                    mutex_set_lock(pool_g, inds[jj], tid);
                    for r in 0..nfactors-1 {
                        ov[r] += v * accumF[r];
                    }
                    mutex_unset_lock(pool_g, inds[jj], tid);
                }
            }
        }
    }

    //***********************************************************************
    private proc p_csf_mttkrp_leaf3_nolock(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
    {
        assert(ct.nmodes == 3);
        const nmodes = ct.nmodes;
        const ref vals = ct.pt[tile_id].vals;
        const ref sptr = ct.pt[tile_id].fptr[0].subtree;
        const ref fptr = ct.pt[tile_id].fptr[1].subtree;
        const ref sids = ct.pt[tile_id].fids[0].fiber_ids;
        const ref fids = ct.pt[tile_id].fids[1].fiber_ids;
        const ref inds = ct.pt[tile_id].fids[2].fiber_ids;

        // pointers to 2D chapel matrices
        const avals = mats[csf_depth_to_mode(ct,0)].vals_ref;
        const bvals = mats[csf_depth_to_mode(ct,1)].vals_ref;
        const ovals = m1.vals_ref;
        const nfactors = mats[nmodes].J;

        // pointer to 1D chapel array
        const accumF = c_ptrTo(thds[tid].scratch[0].buf);

        const nslices = ct.pt[tile_id].nfibs[0];
        const start = partition[tid];
        const stop = partition[tid+1];

        for s in start..stop-1 {
            const fid = if sids[0] == -1 then s else sids[s];
            /* root row */
            const rv = avals + (fid * nfactors);
            /* for each fiber in slice */
            for f in sptr[s]..sptr[s+1]-1 {
                /* fill fiber with hada */
                const av = bvals + (fids[f] * nfactors);
                for r in 0..nfactors-1 {
                    accumF[r] = rv[r] * av[r];
                }
                /* for each nnz in fiber, scale with hada and write to ovals */
                for jj in fptr[f]..fptr[f+1]-1 {
                    const v = vals[jj];
                    const ov = ovals + (inds[jj] * nfactors);
                    for r in 0..nfactors-1 {
                        ov[r] += v * accumF[r];
                    }
                }
            }
        }
    }

    //***********************************************************************
    private proc p_csf_mttkrp_intl3_locked(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
    {
        assert(ct.nmodes == 3);
        const nmodes = ct.nmodes;
        const ref vals = ct.pt[tile_id].vals;
        const ref sptr = ct.pt[tile_id].fptr[0].subtree;
        const ref fptr = ct.pt[tile_id].fptr[1].subtree;
        const ref sids = ct.pt[tile_id].fids[0].fiber_ids;
        const ref fids = ct.pt[tile_id].fids[1].fiber_ids;
        const ref inds = ct.pt[tile_id].fids[2].fiber_ids;

        // pointers to 2D chapel matrices
        const avals = mats[csf_depth_to_mode(ct,0)].vals_ref;
        const bvals = mats[csf_depth_to_mode(ct,2)].vals_ref;
        const ovals = m1.vals_ref;
        const nfactors = mats[nmodes].J;
        
        // pointer to 1D chapel array
        const accumF = c_ptrTo(thds[tid].scratch[0].buf);

        const nslices = ct.pt[tile_id].nfibs[0];
        const start = partition[tid];
        const stop = partition[tid+1];

        for s in start..stop-1 {
            const fid = if sids[0] == -1 then s else sids[s];
            /* root roow */
            const rv = avals + (fid * nfactors);
            /* for each fiber in slice */
            for f in sptr[s]..sptr[s+1]-1 {
                /* first entry of the fiber is used to initialize accumF */
                const jjfirst = fptr[f];
                const vfirst = vals[jjfirst];
                const bv = bvals + (inds[jjfirst] * nfactors);
                for r in 0..nfactors-1 {
                    accumF[r] = vfirst * bv[r];
                }
                /* for each nnz in fiber */
                for jj in (fptr[f]+1)..fptr[f+1]-1 {
                    const v = vals[jj];
                    const bv = bvals + (inds[jj]*nfactors);
                    for r in 0..nfactors-1 {
                        accumF[r] += v * bv[r];
                    }
                }
                /* write to fiber row */
                const ov = ovals + (fids[f] * nfactors);
                mutex_set_lock(pool_g, fids[f], tid);
                for r in 0..nfactors-1 {
                    ov[r] += rv[r] * accumF[r];
                }
                mutex_unset_lock(pool_g, fids[f], tid);
            }
        }
    }

    //***********************************************************************
    private proc p_csf_mttkrp_intl3_nolock(const ct, const tile_id, mats, m1, const mode, const thds, const partition, const tid)
    {
        assert(ct.nmodes == 3);
        const nmodes = ct.nmodes;
        const ref vals = ct.pt[tile_id].vals;
        const ref sptr = ct.pt[tile_id].fptr[0].subtree;
        const ref fptr = ct.pt[tile_id].fptr[1].subtree;
        const ref sids = ct.pt[tile_id].fids[0].fiber_ids;
        const ref fids = ct.pt[tile_id].fids[1].fiber_ids;
        const ref inds = ct.pt[tile_id].fids[2].fiber_ids;

        // pointers to 2D chapel matrices
        const avals = mats[csf_depth_to_mode(ct,0)].vals_ref;
        const bvals = mats[csf_depth_to_mode(ct,2)].vals_ref;
        const ovals = m1.vals_ref;
        const nfactors = mats[nmodes].J;

        // pointer to 1D chapel array
        const accumF = c_ptrTo(thds[tid].scratch[0].buf);

        const nslices = ct.pt[tile_id].nfibs[0];
        const start = partition[tid];
        const stop = partition[tid+1];

        for s in start..stop-1 {
            const fid = if sids[0] == -1 then s else sids[s];
            /* root roow */
            const rv = avals + (fid * nfactors);
            /* for each fiber in slice */
            for f in sptr[s]..sptr[s+1]-1 {
                /* first entry of the fiber is used to initialize accumF */
                const jjfirst = fptr[f];
                const vfirst = vals[jjfirst];
                const bv = bvals + (inds[jjfirst] * nfactors);
                for r in 0..nfactors-1 {
                    accumF[r] = vfirst * bv[r];
                }
                /* for each nnz in fiber */
                for jj in (fptr[f]+1)..fptr[f+1]-1 {
                    const v = vals[jj];
                    const bv = bvals + (inds[jj]*nfactors);
                    for r in 0..nfactors-1 {
                        accumF[r] += v * bv[r];
                    }
                }
                /* write to fiber row */
                const ov = ovals + (fids[f] * nfactors);
                for r in 0..nfactors-1 {
                    ov[r] += rv[r] * accumF[r];
                }
            }
        }
    }

    /*########################################################################
    #   Description:    Should a certain mode be privatized to avoid locks?
    #
    #   Parameters:     csf (splatt_csf[]): Just used for dimensions
    #                   mode (int):         The mode we're processing
    #                   opts (cpd_cmd_args):Arguments
    #
    #   Return:         bool: True if we should privatize
    ########################################################################*/
    private proc p_is_privatized(const csf, const mode : int, const opts : cpd_cmd_args) : bool
    {
        const length : int = csf[0].dims[mode];
        const nthreads : int = opts.numThreads;
        const thresh : real = DEFAULT_PRIV_THRESH;
        // Don't bother if we're not multi-threaded
        if nthreads == 1 {
            return false;
        }
        return ((length *nthreads):real) <= (thresh * csf[0].nnz:real);
    }


    /*########################################################################
    #   Description:    Map MTTKRP functions onto a possibly tiled CSF tensor.
    #                   This function will handle any scheduling required with
    #                   a partitially tiled tensor.
    #
    #   Parameters:     tensors (splatt_csf[]): An array of CSF representations.
    #                                           tensors[csf_id] is processed.
    #                   csf_id (int):           Which tensor are we processing
    #                   mttkrp_func:            An MTTKRP function
    #                   mats:                   The matrices, output stored at mat[nmodes].
    #                   mode:                   Which mode of tensors is the output
    #                   thds:                   Thread workspace
    #                   ws:                     MTTKRP workspace.
    #
    #   Return:         None
    ########################################################################*/
    private proc p_schedule_tiles(const tensors, const csf_id, const mttkrp_func, mats, const mode, const thds, const ws)
    {
        const ref csf = tensors[csf_id];
        const nmodes = csf.nmodes;
        const depth = nmodes-1;
        const nrows = mats[mode].I;
        const ncols = mats[mode].J;

        /* Store old pointer */
        mats[nmodes].vals_ref = c_ptrTo(mats[nmodes].vals);
        const global_output = mats[nmodes].vals_ref;
    
        /* barrier used in p_reduce_privatized */
        const b = new Barrier(numThreads_g);
        const ref tree_partition = ws.tree_partition[csf_id].buf;

        coforall tid in 0..numThreads_g-1 {
            var m1 = new dense_matrix();
            m1.I = mats[nmodes].I;
            m1.J = mats[nmodes].J;
            m1.vals_ref = mats[nmodes].vals_ref;
            
            if ws.is_privatized[mode] {
                /* change (thread-private!) output structure */
                const privBufPtr = c_ptrTo(ws.privatize_buffer[tid].buffer);
                c_memset(privBufPtr, 0, nrows*ncols*8);
                m1.vals_ref = privBufPtr;
            }

            mttkrp_func.func(csf, 0, mats, m1, mode, thds, tree_partition, tid);

            /* If we used privatization, perform a reduction */
            if ws.is_privatized[mode] {
                p_reduce_privatized(ws, global_output, nrows, ncols, tid, b);
            }
        } /* end coforall */
        /* restore pointer */
        mats[nmodes].vals_ref = global_output;
    } 

    /*########################################################################
    #   Description:    Perform a reduction on thread-local MTTKRP output
    #
    #   Parameters:     ws:             MTTKRP workspace.
    #                   global_output:  The global MTTKRP output we are
    #                                   reducing into
    #                   nrows:          Number of rows in MTTKRP
    #                   ncols:          Number of cols in MTTKRP
    #                   tid:            This task's ID
    #                   b:              Barrier to use
    #
    #   Return:         None
    ########################################################################*/
    private proc p_reduce_privatized(const ws, global_output, const nrows, const ncols, const tid, const b)
    {
        /* Ensure everyone has finished their local MTTKRP */
        b.barrier();
        const elem_per_thread = (nrows * ncols) / numThreads_g;
        const start = tid * elem_per_thread;
        const stop = if tid == numThreads_g - 1 then (nrows*ncols) else (tid+1)*elem_per_thread;
        
        /* reduction */
        for t in 0..numThreads_g-1 {
            const thread_buf = c_ptrTo(ws.privatize_buffer[t].buffer);
            for x in start..stop-1 {
                global_output[x] += thread_buf[x];
            }
        }
    }

/*#################################################################################################
#
#   Below are the public functions
#
####################################################################################################*/

    /*****************************
    *
    *   Public Functions
    *
    ******************************/
    
    /*########################################################################
    #   Description:    Allocates splatt_mttkrp_ws
    #
    #   Parameters:     tensors (splatt_csf[]):     Tensor to factor in CSF
    #                   ncolumns (int):             Number of columns in factor
    #                                               matrices
    #                   args (cpd_cmd_args):        Arguments
    #
    #   Return:         splatt_mttkrp_ws class object
    ########################################################################*/
    proc splatt_mttkrp_alloc_ws(const tensors, const ncolumns : int, const opts : cpd_cmd_args) : splatt_mttkrp_ws
    {
        const ws : splatt_mttkrp_ws = new splatt_mttkrp_ws();
        var num_csf : int = 0;
        ws.num_threads = numThreads_g;

        /* map each MTTKRP mode to a CSF tensor */
        for m in 0..tensors[0].nmodes-1 {
            select(opts.numCSF) {
                when "one" {
                    /* only one tensor, map is easy */
                    ws.mode_csf_map[m] = 0;
                    num_csf = 1;
                }
                when "two" {
                    /* last mode is mapped to 2nd tensor */
                    ws.mode_csf_map[m] = 0;
                    if csf_mode_to_depth(tensors[0], m) == tensors[0].nmodes-1 {
                        ws.mode_csf_map[m] = 1;
                    }
                    num_csf = 2;
                }
                when "all" {
                    /* each mode has its own tensor, map is easy */
                    ws.mode_csf_map[m] = m;
                    num_csf = tensors[0].nmodes;
                }
            }
        }
    
        assert(num_csf > 0);
        ws.num_csf = num_csf;

        /* 
            Setup partition info for each CSF.
            Since we aren't doing tiling yet, this will only
            affect the tree partition.

            Below, we use -1 to stand for nil/null
        */
        //ws.tree_part_d = {0..num_csf-1, 0..(ws.num_threads+1)-1};
        ws.tree_d = 0..num_csf-1;
        for c in 0..num_csf-1 {
            ws.tree_partition[c] = new tree_part();
            ws.tree_partition[c].buf = -1;
        }
        // We're not doing tiling, so we just have a "blank" variable for it
        ws.tile_partition = -1;
        for c in 0..num_csf-1 {
            const ref csf = tensors[c];
            ws.tree_partition[c] = csf_partition_1d(csf, 0, ws.num_threads);
        }
        
    
        /* Allocate privatization buffer */
        var largest_priv_dim : int = 0;
        for m in 0..tensors[0].nmodes-1 {
            ws.is_privatized[m] = p_is_privatized(tensors, m, opts);
            if ws.is_privatized[m] == true {
                largest_priv_dim = max(largest_priv_dim, tensors[0].dims[m]);
                writeln("# PRIVATIZING-MODE: ", m+1);
            }
        }
        for t in 0..ws.num_threads-1 {
            ws.privatize_buffer[t] = new priv_buffer();
            ws.privatize_buffer[t].buffer_d = {0..largest_priv_dim-1, 0..ncolumns-1};
        }
        if largest_priv_dim > 0 {
            const bytes = ws.num_threads * largest_priv_dim * ncolumns * 8;
            const bstr = bytes_str(bytes);
            writeln("# PRIVATIZATION-BUF: ", bstr);
            writeln("");
        }
        return ws;
    }

    /*########################################################################
    #   Description:    Matricized Tensor Times Khatri-Rao Product (MTTKRP)
    #                   with a CSF tensor. This is the primary computation
    #                   involved in CPD. Output is written to mats[nmodes].
    #
    #   Parameters:     tensors (splatt_csf[]): Tensor to factor in CSF
    #                   mats (dense_matrix[]):  Input/output matrices
    #                   mode (int):             Which mode we are computing for
    #                   thds (thd_info[]):      Thread scratch space
    #                   ws (splatt_mttkrp_ws):  MTTKRP workspace
    #                   opts (cpd_cmd_args):    Arguments.
    #
    #   Return:         None
    ########################################################################*/
    proc mttkrp_csf(const tensors, mats, const mode : int, const thds, const ws : splatt_mttkrp_ws, const opts)
    {
        // Set up mutex pool. The pool itself is global
        pool_g = mutex_alloc(DEFAULT_NLOCKS, DEFAULT_LOCK_PAD);
        
        const nmodes = tensors[0].nmodes;

        /* Clear output matrix */
        const ref M = mats[nmodes];
        M.I = tensors[0].dims[mode];
        //M.matrix_domain = {0..M.I-1, 0..M.J-1};
        M.vals = 0.0;
        M.vals_ref = c_ptrTo(M.vals);
        c_memset(M.vals_ref, 0, 8*M.I*M.J);

        /* Choose which MTTKRP function to use */
        const which_csf = ws.mode_csf_map[mode];
        const outdepth = csf_mode_to_depth(tensors[which_csf], mode);
        if outdepth == 0 {
            /* root */
            if ws.is_privatized[mode] {
                /* don't use atomics */
                const mttkrp_func = new mttkrp_root_nolock();
                p_schedule_tiles(tensors, which_csf, mttkrp_func, mats, mode, thds, ws);
                delete mttkrp_func;
            }
            else {
                const mttkrp_func = new mttkrp_root_locked();
                p_schedule_tiles(tensors, which_csf, mttkrp_func, mats, mode, thds, ws);
                delete mttkrp_func;
            }
        }
        else if outdepth == nmodes-1 {
            /* leaf */
            if ws.is_privatized[mode] {
                /* don't use atomics */
                const mttkrp_func = new mttkrp_leaf_nolock();
                p_schedule_tiles(tensors, which_csf, mttkrp_func, mats, mode, thds, ws);
                delete mttkrp_func;
            }
            else {
                const mttkrp_func = new mttkrp_leaf_locked();
                p_schedule_tiles(tensors, which_csf, mttkrp_func, mats, mode, thds, ws);
                delete mttkrp_func;
            }
        }
        else {
            /* internal */
            if ws.is_privatized[mode] {
                /* don't use atomics */
                const mttkrp_func = new mttkrp_intl_nolock();
                p_schedule_tiles(tensors, which_csf, mttkrp_func, mats, mode, thds, ws);
                delete mttkrp_func;
            }
            else {
                const mttkrp_func = new mttkrp_intl_locked();
                p_schedule_tiles(tensors, which_csf, mttkrp_func, mats, mode, thds, ws);
                delete mttkrp_func;
            }
        }
    }
}
