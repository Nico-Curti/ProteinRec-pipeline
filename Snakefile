# snakemake --cores 8                   # to run
# snakemake -n                          # check workflow
# REMEMBER REMEMBER : pipe in powershell wraps the object into utf-16 char set (avoid it...evil!)
# WIN32 :=  cmd /C "snakemake --dag | dot -Tpdf > workflow.pdf"
# UNIX  :=  snakemake --dag | dot -Tpdf > workflow.pdf

from __future__ import division
import numpy as np
import pandas as pd

# pipeline of protein reconstruction
import os # local, sep, files, dirs
import sys # exit
import platform # check system
import shutil # move file
import subprocess # capture output
import scipy # squareform, pdist, csgraph, eigsh
import functools # map with multiple args
from string import Template # template string cmd OS
import itertools # combination

# plots of results
import seaborn as sns # pretty/easy plots with pandas
import matplotlib.pylab as plt # plots

configfile: "config.yaml"

np.random.seed(int(config["seed"])) # random number generator
sns.set_context("paper", font_scale=1.5)
sep             =   os.sep
local           =   os.path.abspath(".")
if platform.system() == "Windows":
    extension   =   ".exe"
    build       =   "powershell .\\build.ps1"
    myshell     =   ".ps1"
    extract     =   Template('7z x $pdb & rename *.cif *.pdb')
elif platform.system() == "Linux" or platform.system()[:6] == "CYGWIN":
    extension   =   ""
    build       =   'bash -c "./build.sh"'
    myshell     =   ".sh"
    extract     =   Template("gunzip -k $pdb; rename 's/\.cif$/\.pdb/' *.cif")

pdb_extension   =   config["pdb_ext"]
atoms           =   list(config["atoms"]) # type of atoms to conserve
thr             =   int(config["thr"]) # threashold distance for contact map
n_population    =   int(config["n_population"]) # number of dna to use in GA
max_iter        =   int(config["max_iter"]) # max number of generation in GA
precision       =   float(config["precision"]) # minimum rmsd accepted
elit_rate       =   float(config["elit"]) # percentage of population to conserve in GA
mutation_rate   =   float(config["mutation"]) # probability of mutation

# folders
pdb_dir         =   config["folders"]["pdb_dir"] # directory of pdb files
cpp             =   config["folders"]["cpp"]
scripts         =   config["folders"]["py"]

# thread rules
nth_pdb2xyz     =   int(config["NTH_PDB2XYZ"])
nth_guess       =   int(config["NTH_GUESS"])
nth_genetic     =   int(config["NTH_GENETIC"])

ELIT = n_population * elit_rate
HALF = n_population / 2
protein = list(config["protein"]) 

def kabsch(pt_true, pt_guessed):
    # Translation
    pt_true -= pt_true.mean(axis = 0)
    pt_guessed -= pt_guessed.mean(axis = 0)

    # Scaling
    pt_true /= np.linalg.norm(pt_true, axis=0)
    pt_guessed /= np.linalg.norm(pt_guessed, axis=0) # pt_guessed already normalized to 1 when eig results

    # find right permutation of axis 
    combo = list(itertools.permutations(["x", "y", "z"]))
    permutation = list(combo[ np.argmax( [ sum([ scipy.stats.pearsonr(x=pt_true[true], y=pt_guessed[guess])[0] 
                                           for true, guess in zip(["x","y","z"], list(comb))
                                          ]) 
                                        for comb in combo ]
                                        )])

    # Computation of the optimal rotation matrix
    # This can be done using singular value decomposition (SVD) 
    # of the covariance matrix.
    # Getting the sign of the det(V)*(W) to decide
    # whether we need to correct our rotation matrix to ensure a
    # right-handed coordinate system.
    # And finally calculating the optimal rotation matrix U
    V, S, W = np.linalg.svd( np.dot(pt_true.T, pt_guessed[permutation]) ) # SVD of covariance matrix
    d = (np.linalg.det(V) * np.linalg.det(W)) < 0.0
    if d:
        S[-1] = -S[-1]
        V[:, -1] = -V[:, -1]
    return pd.DataFrame(data = np.dot(pt_guessed[permutation], np.dot(V, W)), columns=["x", "y", "z"]) # return pt_guessed rotated by U ( = V * W, rotation matrix)

def random_population(cmap, N, scale = 1e-2):
    weights = [np.triu(np.random.normal(loc=0.0, scale=scale, size=(len(cmap), len(cmap))) * cmap) for i in range(N)]
    return [w + w.T for w in weights] # symmetric matrix

def get_cmap(protein, thr):
    return scipy.sparse.csc_matrix(scipy.spatial.distance.squareform(scipy.spatial.distance.pdist(protein.iloc[:,1:], metric="euclidean") < thr), dtype=np.float)

def get_lap(cmap):
    return scipy.sparse.csc_matrix(scipy.sparse.csgraph.laplacian(cmap, normed=False))

def laplacian_coords(protein, thr):
    """
    Computing of laplacian (eigenvalues, eigenvectors) of contact map
    """
    _, vecs = scipy.sparse.linalg.eigsh(A=get_lap(cmap=get_cmap(protein=protein, thr=thr)), k=4, sigma=0)
    return vecs[:, 1:4] # remove first eigenvalue (null) and corresponding eigenvector

def mutate(cmap, type = "strong", scale=1e-2):
    if type == "strong":
        """
        mutation of an entire row and column
        """
        pos = int(np.random.uniform(low=0, high=len(cmap), size=1))
        new = np.random.normal(loc=0.0, scale = scale, size=len(cmap))
        cmap[pos] = new * cmap[pos]
        cmap[:, pos] = cmap[pos]
    elif type == "weak":
        """
        mutation of only one weight
        """
        nn = np.nonzero(cmap)
        pos = int(np.random.uniform(low=0, high=len(nn[0]), size=1))
        cmap[pos[0], pos[1]] = np.random.normal(loc=0.0, scale = scale, size=1)
    return cmap

def crossover(cmap_a, cmap_b):
    """
    Cross over as submatrix of A extracted as random permutation and B
    """
    rn = np.arange(len(cmap_a))
    np.random.shuffle(rn)
    pos = int(np.random.uniform(low=0, high=len(cmap_a), size=1))
    W = cmap_b
    W[:pos, :pos] = cmap_a[rn[:pos]][:, rn[:pos]]
    return W

def new_generation(old_generation, rank, elit_rate = ELIT, mutation_rate = mutation_rate, half = HALF, type = "strong"):
    # crossover
    # REALLY BIG TROUBLES
    if i < ELIT:
        new_gen = population[i]
    else:
        new_gen = crossover(population[rank[np.random.rand() * HALF]], population[rank[np.random.rand() * HALF]])
    # mutation
    if np.random.rand() < mutation_rate:
        new_gen = mutate(new_gen, type)
    return new_gen

def fitness(protein_a, protein_b):
    """
    Sum of square differences of coordinates
    """
    return np.sqrt( np.sum((protein_a - protein_b)**2, axis=1) / len(protein_a))

def protein_pipe(weights, real_coords, guess_cmap, thr=8):
    w = np.sqrt(weights)
    # BIG TROUBLES
    guess_coords = laplacian_coords( protein=np.einsum('ij,jk,lk->il', w, guess_cmap, w.T), thr=thr ) # product w*A*w^T
    return fitness(real_coords, kabsch(real_coords, guess_coords) ) 


rule all:
    input:
        db_compare = os.path.join(local, "db_compare.csv"),

rule download:
    input:
    output:
        pdb = os.path.join(local, pdb_dir, "{protein}.pdb"),
    benchmark:
        os.path.join("benchmark", "benchmark_download")
    message:
        "Download of protein {wildcards.protein}"
    log:
        "logs/download/{protein}.log"
    shell:
        'curl "http://files.rcsb.org/view/{wildcards.protein}.pdb" -o {output.pdb} 2> {log}'

rule build:
    input:
        os.path.join(local, cpp, "pdb2xyz.cpp"),
        os.path.join(local, "build" + myshell),
    output:
        os.path.join(local, "bin", "pdb2xyz" + extension)
    benchmark:
        os.path.join("benchmark", "benchmark_build.dat")
    message:
        "Building softwares"
    shell:
        build

rule uncompress:
    input:
        os.path.join(local, pdb_dir, "{protein}.gz")
    output:
        os.path.join(local, pdb_dir, "{protein}." + pdb_extension)
    benchmark:
        os.path.join("benchmark", "benchmark_uncompress.dat")
    message:
        "Uncompress protein {wildcards.protein}"
    shell:
        extract.substitute(pdb="{wildcards.protein}")

rule pdb2xyz:
    input:
        pdbfile  = os.path.join(local, pdb_dir, "{protein}"),
    output:
        out      = os.path.join(local, pdb_dir, "{protein}." + "xyz"),
    benchmark:
        os.path.join("benchmark", "benchmark_pdb2xyz_{protein}.dat")
    threads:
        nth_pdb2xyz 
    message:
        "Conversion PDB2xyz for {wildcards.protein}"
    log:
        "logs/pdb2xyz/{protein}.log"
    shell:
        ' '.join([os.path.join(local, "bin", "pdb2xyz" + extension), "{input.pdbfile}", "-s", ' '.join(atoms)])

rule guess_protein:
    input:
        coord_file = os.path.join(local, pdb_dir, "{protein}." + pdb_extension + ".xyz"),
    output:
        guess_file = os.path.join(local, pdb_dir, "{protein}." + pdb_extension + ".guess")
    benchmark:
        os.path.join("benchmark", "benchmark_reconstruction_{protein}.dat")
    threads:
        nth_guess
    message:
        "Simple reconstruction protein for {wildcards.protein}"
    run:
        coords = pd.read_csv(input.coord_file, sep="\t", header=None, names=["atoms", "x", "y", "z"])
        pd.concat([coords["atoms"], kabsch( pt_true=coords.iloc[:,1:], # remove atoms columns
                                            pt_guessed=pd.DataFrame(data=laplacian_coords(protein=coords, thr=thr), columns=["x", "y", "z"]) # dataset with only eigenvecs
                                            )], axis=1).to_csv(output.guess_file, sep="\t", header=False, index=False)

rule compare:
    input:
        true_coords = expand(os.path.join(local, pdb_dir, "{protein}." + pdb_extension + ".xyz"), protein=protein),
        rec_coords = expand(os.path.join(local, pdb_dir, "{protein}." + pdb_extension + ".guess"), protein=protein),
    output:
        db_compare = os.path.join(local, "db_compare.csv"),
    benchmark:
        os.path.join("benchmark", "benchmark_compare.dat")
    message:
        "Compare proteins"
    run:
        with open(output.db_compare, "w") as out:
            out.write("pdb_name\tnCA\ttot_dist\trmsd\taxis\n")
            for true, guess in zip(input.true_coords, input.rec_coords):
                tcoord = pd.read_csv(true, sep="\t", header=None, names=["atoms", "x", "y", "z"]).iloc[:, 1:]
                gcoord = pd.read_csv(guess, sep="\t", header=None, names=["atoms", "x", "y", "z"]).iloc[:, 1:]

                # Translation
                tcoord -= tcoord.mean(axis = 0)
                gcoord -= gcoord.mean(axis = 0)

                # Scaling
                tcoord /= np.linalg.norm(tcoord, axis=0)
                gcoord /= np.linalg.norm(gcoord, axis=0) # gcoord already normalized to 1 when eig results

                # find right permutation of axis 
                combo = list(itertools.permutations(["x", "y", "z"]))
                permutation = list(combo[ np.argmax( [ sum([ scipy.stats.pearsonr(x=tcoord[true], y=gcoord[guess])[0] 
                                                       for true, guess in zip(["x","y","z"], list(comb))
                                                      ]) 
                                                    for comb in combo ]
                                                    )])

                tot_dist =  np.sum( np.sqrt( np.sum( (tcoord - gcoord[permutation])**2, axis=1) ) )
                pdb_name = true.split(os.sep)[-1].split(".")[0]
                out.write("%s\t%d\t%.3f\t%.3f\t%s\n"%(pdb_name, len(tcoord), tot_dist, tot_dist / len(tcoord), ';'.join(map(str, permutation))))


rule reconstructGA:
    input:
        coord_file = os.path.join(local, pdb_dir, "{protein}." + pdb_extension + ".xyz"),
        guess_file = os.path.join(local, pdb_dir, "{protein}." + pdb_extension + ".guess"),
    output:
        rec_file  = os.path.join(local, pdb_dir, "{protein}.rec")
    benchmark:
        os.path.join("benchmark", "benchmark_GA_{protein}.dat")
    threads:
        nth_genetic
    message:
        "GA reconstruction protein for {wildcards.protein}"
    run:
        protein_true  = pd.read_csv(input.coord_file, sep="\t", header=None, usecols=["x", "y", "z"], names=["atoms", "x", "y", "z"])
        protein_guess = pd.read_csv(input.guess_file, sep="\t", header=None, usecols=["x", "y", "z"], names=["atoms", "x", "y", "z"])
        cmap_guess = get_cmap(protein_guess, thr=thr)
        population = random_population(cmap=cmap_guess, N=n_population, scale=1e-2)

        for generation in range(max_iter):
            fit = list(map(functools.partial(protein_pipe, real_coords=protein_true, guess_cmap=cmap_guess, thr=thr), population))
            idx = np.argsort(fit)
            best = idx[0]
            if fit[best] < precision:
                break
            population = list(map(functools.partial(new_generation, rank=idx, elit_rate = ELIT, mutation_rate = mutation_rate, half = HALF, type = "strong"), population))
        population[best].to_csv(output.rec_file, sep=",", header=False, index=False)

    