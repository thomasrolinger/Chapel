/*
    Author: Thomas Rolinger (tbrolin@cs.umd.edu)
    Date:   12/07/2017
    File:   util.chpl

    Description:    This is a module file that contains misc. utility
                    functions
*/

module Util {
    use IO.FormattedIO;
    use Kruskal;
    use Random;
    /* 
        Takes a value (number of bytes) and produces a printable
        string that represents the size (i.e. B, KB, MB, etc.)
    */
    proc bytes_str(bytes : int) : string
    {
        var size: real = bytes:real;
        var suff: int = 0;
        var suffix: [0..4] string;
        suffix = ["B", "KB", "MB", "GB", "TB"];
        while (size > 1024 && suff < 5) {
            size /= 1024;
            suff += 1;
        }
        var ret : string = "%0.2dr%s".format(size, suffix[suff]);
        return ret;
    }

    /*
        Given a factor matrix, generate random values for its
        data. Use the global random stream.
    */
    proc mat_rand(mat : dense_matrix, m)
    {
        /*forall (i,j) in mat.vals.domain {
            var v : real = 3.0 * (randStream_g.getNext():real / RAND_MAX:real);
            var v2 : int = randStream_g.getNext();
            if v2 % 2 == 0 {
                v *= -1;
            }
            mat.vals(i,j) = v;
        }*/
        //$$$$ TEMPORARY $$$$$$
        /*
            Since Chapel and C have different RNGs and I need to have
            the same values in the factor matrices while testing this
            code, we will read in the matrix values from a file for now. 
        */
        var fin : file;
        if m == 0 {
            fin = open("factMats_A.txt", iomode.r);
        }
        else if m == 1 {
            fin = open("factMats_B.txt", iomode.r);
        }
        else {
            fin = open("factMats_C.txt", iomode.r);
        }
        var reader = fin.reader();
        reader.read(mat.vals);
        reader.close();        
        
    }
}
