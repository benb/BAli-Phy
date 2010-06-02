#!/usr/bin/perl -w 

# TODO

# !! For alignment-diff, invert fg/bg based on AU>0.5 (bg=white,fg=color)
#    Would look cool!
#    Or, us color (DNA/AA) only if AU<0.5

# !! How to select alignments from a given temperature level?
#    Annotate alignments with information... ?


# 1. Histogram for distribution of each statistic.
# 2. alignment properties (#indels, etc)
# 3. alphabet of each partition
# 4. Somehow print posterior distribution of # of indels (really)
#    and substitutions (really - not just parsimony score?)     
# 5. Include links from top to sections.

# FIX: Handling different temperatures is probably broken:
#      + Treat every chain as a separate run.
#      + However, select out the samples with beta=1
# PROBLEM: Our output format of separate files makes it difficult to 
#            selecting trees & alignments with a given temperature.
#          I suppose we could write out a list of iterations to select, and then
#            select them using that.
#
#          This may be related to the fact that it is hard to subsample alignments
#          because our current format (a giant list) makes it hard to tag them with info.


use strict;

use Carp;

use POSIX;

my $home = $ENV{'HOME'};

#----------------------------- SETUP 1 --------------------------#

if (! is_in_path("trees-consensus")) {
    print "I can't find the program 'trees-consensus' in your PATH!\n";
    print "See the manual for adding the bali-phy programs to your PATH\n";
    exit(1);
}

my $have_draw_tree = 1;

if (! is_in_path("draw-tree")) {
    print "Program 'draw-tree' not found.  Tree pictures will not be generated.\n\n";
    $have_draw_tree = 0;
}

my $have_gnuplot = 1;

if (! is_in_path("gnuplot")) {
    print "Program 'gnuplot' not found.  Trace plots will not be generated.\n\n";
    $have_gnuplot = 0;
}

my $have_R = 1;

if (! is_in_path("R")) {
    print "Program 'R' not found.  Some mixing graphs will not be generated.\n\n";
    $have_gnuplot = 0;
}

my $personality="";
my $out_file;
my $trees_file;
my $parameters_file;
my $n_chains=1;
my @directories;
my @out_files;
my @tree_files;
my @parameter_files;
my @partition_samples;
my $MAP_file;
my $burnin;
my $max_iter;
my $subsample = 1;
my $min_support;
my $muscle = 0;
my $probcons = 0;
my $sub_partitions=0;
my $do_consensus_alignments=0;
my $prune;
my $speed=1;

&parse_command_line();

&determine_personality();

&determine_input_files();

my $command = get_header_attribute($out_files[0],"command");
my $directory = get_header_attribute($out_files[0],"directory");
my @subdirs    = get_header_attributes("subdirectory",@out_files);

my $betas = get_cmdline_attribute("beta");
my @beta = (1);
@beta = split(/,/, $betas) if (defined($betas));

my $first_dir = $directories[0];
my @partitions = @{ get_partitions() };
my $n_partitions = 1+$#partitions;
if ($personality =~ "bali-phy-2.1.*") {
    if ($n_chains == 1) {
	foreach my $directory (@directories)
	{
	    my @samples = ();
	    for(my $p=1;$p<=$n_partitions;$p++) {
		push @samples,"$directory/C1.P$p.fastas";
	    }
	    push @partition_samples, [@samples];
	}
    }
    else {
	## FIXME - How do we construct these?
	my @samples = ();
	for(my $p=1;$p<=$n_partitions;$p++) {
	    push @samples,"$first_dir/C1.P$p.fastas";
	}
	push @partition_samples, [@samples];
    }
}
else {
    my @samples = ();
    for(my $p=1;$p<=$n_partitions;$p++) {
	push @samples,"$first_dir/1.P$p.fastas" if (-e "$first_dir/1.P$p.fastas");
    }
    @samples = ("$first_dir/1.out") if ($#samples == -1);
    push @partition_samples, [@samples];
}


my $n_iterations = get_n_iterations();
my @smodels = @{ get_smodels() };
my @imodels = @{ get_imodels() };

my @smodel_indices = @{ get_smodel_indices() };
push @smodel_indices,0 if ($#smodel_indices == -1);

my @imodel_indices = @{ get_imodel_indices() };
if ($#imodel_indices == -1)
{
    if ($#imodels == -1 || $imodels[0] eq "none") {
	push @imodel_indices,-1;
    }
    else {
	push @imodel_indices,0;
    }
}

my @alphabets = get_alphabets();

my %tree_name = ();
# This is necessary to display them in order:
my @trees = (); 

#

my @tree_consensus_values = sort(0.5,0.66,0.8,0.9,0.95,0.99,1.0);

my @alignment_consensus_values;
if ($speed == 0) {
    @alignment_consensus_values = sort(0.1,0.25,0.5,0.75);
}
elsif ($speed == 1) # default
{
    @alignment_consensus_values = (0.5);
}
elsif ($speed == 2) {
    @alignment_consensus_values = ();
}


$burnin = int 0.1*$n_iterations if (!defined($burnin));
my $after_burnin = $n_iterations - $burnin +1;

do_init();

# 0. Compute T1.p and T1.trees

if ($n_chains > 1) 
{
    for(my $i=1;$i<=$n_chains;$i++)
    {
	# Construct C1.pt
	# Construct C1Ti.pt
	# Construct C1Ti.p
	# Construct C1Ti.trees
	next if (! -e "C$i.trees" );

	if (! more_recent_than("Results/C$i.t","C$i.trees"))
	{
	    `echo "tree" > Results/C$i.t`;
	    `cat C$i.trees >> Results/C$i.t`;
	}
	
	if (! more_recent_than_all_of("Results/C$i.pt",["C$i.trees","C$i.p"]))
	{
	    `stats-merge C$i.p Results/C$i.t > Results/C$i.pt 2>/dev/null`;
	}

	if (! more_recent_than("Results/C${i}T1.pt","Results/C$i.pt")) 
	{
	    my $use_header = "";
	    $use_header = "--no-header" if ($i != 1);

	    `subsample --header --skip=$burnin < Results/C$i.pt | stats-select -s beta=1 $use_header > Results/C${i}T1.pt`;
	}
    }

    my $cmd = "cat ";
    my $rerun=0;
    for(my $i=1;$i<=$n_chains;$i++) {
	if (-e "Results/C${i}T1.pt") {
	    $cmd = "$cmd Results/C${i}T1.pt ";
	    $rerun=1 if (! more_recent_than("Results/T1.p","Results/C${i}T1.pt"));
	}
    }
    $cmd = "$cmd > Results/T1.pt";
    `$cmd` if ($rerun);

    if (! more_recent_than("Results/T1.trees","Results/T1.pt")) {
	`stats-select tree --no-header < Results/T1.pt > Results/T1.trees`;
    }
    
    if (! more_recent_than("Results/T1.p","Results/T1.pt")) {
	`stats-select -r tree < Results/T1.pt > Results/T1.p`;

#       This messes up the printing of statistics
#	`stats-select -i -r tree < Results/T1.pt > Results/T1.p`;

    }

    $trees_file = "Results/T1.trees";
    $parameters_file = "Results/T1.p";
}

# 5. Summarize scalar parameters
my $max_arg = "";
$max_arg = "--max=$max_iter" if (defined($max_iter));

my $skip="";
$skip="--skip=$burnin" if ($trees_file ne "Results/T1.trees");

my $subsample_string = "--sub-sample=$subsample";
$subsample_string = "" if ($subsample == 1);

if ($personality =~ "bali-phy.*" || $personality eq "beast" || $personality eq "phylobayes") {
    print "Summarizing distribution of numerical parameters...";
    if (! more_recent_than("Results/Report",$parameters_file)) {
	`statreport $subsample_string $max_arg $skip @parameter_files > Results/Report`;
    }
    print "done.\n";
}
    
# 1. compute consensus trees
my $min_support_arg = "";
$min_support_arg = "--min-support=$min_support" if (defined($min_support));

my $consensus_no_pp_arg = "--consensus=". get_consensus_arg("tree",\@tree_consensus_values);
my $consensus_pp_arg = "--consensus-PP=". get_consensus_arg("PP.tree",\@tree_consensus_values);
my $e_consensus_arg = "";
$e_consensus_arg = "--extended-consensus=". get_consensus_arg("mtree",\@tree_consensus_values) if ($sub_partitions);
my $el_consensus_arg = "";
$el_consensus_arg = "--extended-consensus-L=". get_consensus_arg("mlengths",\@tree_consensus_values) if ($sub_partitions);
my $consensus_arg = "$consensus_no_pp_arg $consensus_pp_arg $e_consensus_arg $el_consensus_arg";

my $size_arg = "";
$size_arg = "--size=$max_iter" if defined($max_iter);
my $prune_arg = "";
my $prune_arg2 = "";

print "\nSummarizing topology distribution ... ";
if (-z "Results/consensus" || ! more_recent_than("Results/consensus",$trees_file)) {
    my $sub_string = "--sub-partitions";
    $sub_string = "" if (!$sub_partitions);
    $prune_arg = "--ignore $prune" if (defined($prune));

    my $select_trees_arg = "$max_arg $skip $subsample_string $prune_arg";
    my $levels_arg = "--support-levels=Results/c-levels.plot";
    $levels_arg = "$levels_arg --extended-support-levels=Results/extended-c-levels.plot" if ($sub_partitions);
    `trees-consensus @tree_files $select_trees_arg $min_support_arg $sub_string $consensus_arg $levels_arg --map-tree=Results/MAP.tree > Results/consensus`;
}
print "done.\n";

# 2. Draw trees

for my $cvalue (@tree_consensus_values)
{
    my $value = $cvalue*100;
    my $tree = "c$value";
    $tree_name{$tree} = "$value\% consensus";
    push @trees,$tree;
}
push @trees, "MAP";
$tree_name{"MAP"} = "MAP";

&draw_trees();


# 10. Mixing diagnostics -- block bootstrap
print "\nGenerate mixing diagnostics for topologies ... ";

if (!more_recent_than("Results/partitions","Results/consensus")) {
    `pickout --no-header --large pi < Results/consensus > Results/partitions`;
}
if (!more_recent_than("Results/partitions.pred","Results/partitions")) {
    `perl -e 'while(<>) {s/\$/\\n/;print;}' < Results/partitions > Results/partitions.pred`;
}

if (!more_recent_than("Results/partitions.bs",$trees_file)) {
    my $trees_arg = join(':',@tree_files);
    `trees-bootstrap $max_arg $trees_arg $skip $subsample_string --pred Results/partitions.pred --LOD-table=Results/LOD-table --pseudocount 1 > Results/partitions.bs`;
}
print "done.\n";

if (!more_recent_than("Results/convergence-PP.pdf",$trees_file))
{
    my $script = find_in_path("compare-runs.R");
    die "can't find script!" if (!defined($script));
    Rexec($script,"Results/LOD-table Results/convergence-PP.pdf");
}

# 11. c-levels.plot - FIXME!

if ($have_gnuplot) {
if ($sub_partitions) {
`gnuplot <<EOF
set terminal svg
set output "Results/c-levels.svg"
set xlabel "Log10 posterior Odds (LOD)"
set ylabel "Supported Splits"
set style data lines
plot [0:][0:] 'Results/c-levels.plot' title 'Full Splits','Results/extended-c-levels.plot' title 'Partial Splits'
EOF`;
}
else {
`gnuplot <<EOF
set terminal svg
set output "Results/c-levels.svg"
set xlabel "Log10 posterior Odds (LOD)"
set ylabel "Supported Splits"
plot [0:][0:] 'Results/c-levels.plot' with lines notitle
EOF`;
}
}

# 6. Compute initial alignments

my @alignments = ();
my @AU_alignments = ();
my %alignment_names = ();

if ($personality =~ "bali-phy.*") {
    print "\nComputing initial alignments... ";
    for(my $i=0;$i<$n_partitions;$i++)
    {
	my $p = $i+1;
	my $name = "P$p-initial";
	push @alignments,$name;
	$alignment_names{$name} = "Initial";
	
	# These initial alignments should never change!
	if (! -s "Results/Work/$name-unordered.fasta") {
	    `alignment-find --first < $partition_samples[0][$i] > Results/Work/$name-unordered.fasta 2>/dev/null`;
	    if ($? && $n_chains==1 && defined($MAP_file)) {
		`alignment-find --first < $MAP_file > Results/Work/$name-unordered.fasta`;
	    }
	}
    }
    print "done.\n";
}

# 6.5. Compute MUSCLE alignments

if ($personality =~ "bali-phy.*") {
    if ($muscle) {
	print "\nComputing MUSCLE alignment... ";

	for(my $i=0;$i<$n_partitions;$i++) {
	    my $p = ($i+1);
	    my $name = "P$p-muscle";
	    if (! more_recent_than("Results/Work/$name-unordered.fasta", "Results/Work/P$p-initial-unordered.fasta")) {
		`muscle -in Results/Work/P$p-initial-unordered.fasta -out Results/Work/$name-unordered.fasta -quiet`;
	    }
	    push @alignments,$name;
	    $alignment_names{$name} = "MUSCLE";
	    
	}
	print "done.\n";
    }
}

# 6.5. Compute ProbCons alignments

if ($personality =~ "bali-phy.*") {
    if ($probcons) {
	print "\nComputing ProbCons alignment... ";
	
	for(my $i=0;$i<$n_partitions;$i++) {
	    my $p = ($i+1);
	    my $name = "P$p-probcons";
	    
#    my $alignment_info = get_alignment_info("Results/Work/P$p-initial-unordered.fasta");
	    my $alphabet = $alphabets[$i];
	    
	    if ($alphabet =~ /RNA nucleotides/) {
		print "got here\n";
		if (! more_recent_than("Results/Work/$name-unordered.fasta", "Results/Work/P$p-initial-unordered.fasta")) {
		    `probcons-RNA Results/Work/P$p-initial-unordered.fasta > Results/Work/$name-unordered.fasta 2>/dev/null`;
		}
	    }
	    elsif (! more_recent_than("Results/Work/$name-unordered.fasta", "Results/Work/P$p-initial-unordered.fasta")) {
		`probcons Results/Work/P$p-initial-unordered.fasta > Results/Work/$name-unordered.fasta 2>/dev/null`;
	    }
	    push @alignments,$name;
	    $alignment_names{$name} = "ProbCons";
	    
	}
	print "done.\n";
    }
}

&compute_wpd_alignments();

&compute_consensus_alignments() if ($do_consensus_alignments);

if ($#alignments != -1) {
    print "Drawing alignments... ";
    for my $alignment (@alignments) 
    {
	if (! more_recent_than("Results/$alignment.fasta","Results/Work/$alignment-unordered.fasta") ||
	    ! more_recent_than("Results/$alignment.fasta","Results/c50.tree")) {
	    `alignment-reorder Results/Work/$alignment-unordered.fasta Results/c50.tree > Results/$alignment.fasta`;
	}
	
	if (! more_recent_than("Results/$alignment.html","Results/$alignment.fasta")) {
	    `alignment-draw Results/$alignment.fasta --show-ruler --color-scheme=DNA+contrast > Results/$alignment.html 2>/dev/null`;
	    
	    if ($?) {
		`alignment-draw Results/$alignment.fasta --show-ruler --color-scheme=AA+contrast > Results/$alignment.html`;
	    }
	}
    }
}

for my $alignment (@alignments) 
{
    my $p;
    if ($alignment =~ /^P([^-]+)-/) {
	$p=$1;
	next if ($imodel_indices[$p-1] == -1);
    }
    else {
	next;
    }

    next if ($alignment eq "P$p-max");
    next if (! -e "Results/P$p-max.fasta");

    if (! more_recent_than("Results/$alignment-diff.fasta","Results/$alignment.fasta") || 
	! more_recent_than("Results/$alignment-diff.AU","Results/$alignment.fasta") )
    {
	`alignments-diff Results/$alignment.fasta Results/P$p-max.fasta --merge --fill=unknown -d Results/$alignment-diff.AU > Results/$alignment-diff.fasta`;
    }

    if (! more_recent_than("Results/$alignment-diff.html","Results/$alignment-diff.fasta")) {
	`alignment-draw Results/$alignment-diff.fasta --scale=invert --AU Results/$alignment-diff.AU --show-ruler --color-scheme=Rainbow+fade[1,0]+contrast > Results/$alignment-diff.html`;
    }
}
print "done.\n";

# 8. AU plots

for my $alignment (@AU_alignments) 
{
    if ($alignment =~ /^P([^-]+)-.*/) {
	print "Generating AU values for $alignment... ";
	my $p = $1;
	my $infile = $partition_samples[0][$p-1];

	if (!more_recent_than("Results/$alignment-AU.prob",$infile)) {
	`cut-range --skip=$burnin $size_arg < $infile | alignment-gild Results/$alignment.fasta Results/MAP.tree --max-alignments=500 > Results/$alignment-AU.prob`;
	}
	print "done.\n";
	`alignment-draw Results/$alignment.fasta --show-ruler --AU Results/$alignment-AU.prob --color-scheme=DNA+contrast+fade+fade+fade+fade > Results/$alignment-AU.html 2>/dev/null`;
	if ($?) {
	`alignment-draw Results/$alignment.fasta --show-ruler --AU Results/$alignment-AU.prob --color-scheme=AA+contrast+fade+fade+fade+fade > Results/$alignment-AU.html`;
	}
    }
}

# 9. Estimate marginal likelihood
my $marginal_prob = "unknown";
if ($personality ne "treefile") 
{
    print "Calculating marginal likelihood... ";

    if (!more_recent_than("Results/Pmarg",$parameters_file)) {
	my $likelihood = "likelihood";
	$likelihood = "loglik" if ($personality eq "phylobayes");
	`stats-select $likelihood --no-header < $parameters_file | tail -n+$burnin | model_P > Results/Pmarg`;
    }
    print "done.\n";
    $marginal_prob = `cat Results/Pmarg`;
}



# 12. Mixing diagnostics - SRQ plots
my @SRQ = ();

print "Generate SRQ plot for partitions ... ";
if (!more_recent_than("Results/partitions.SRQ",$trees_file)) {
`trees-to-SRQ Results/partitions.pred $max_arg $skip $subsample_string --max-points=1000 < $trees_file > Results/partitions.SRQ`;
}
print "done.\n";

push @SRQ,"partitions";

print "Generate SRQ plot for c50 tree ... ";
if (!more_recent_than("Results/c50.SRQ",$trees_file)) {
`trees-to-SRQ Results/c50.tree $max_arg $subsample_string $skip --max-points=1000 < $trees_file > Results/c50.SRQ`;
}
print "done.\n";

push @SRQ,"c50";

if ($have_gnuplot) {
for my $srq (@SRQ) {
`gnuplot <<EOF
set terminal png size 300,300
set output "Results/$srq.SRQ.png"
set key right bottom
set xlabel "Regenerations (fraction)"
set ylabel "Time (fraction)"
set title "Scaled Regeneration Quantile (SRQ) plot: $srq"
plot 'Results/$srq.SRQ' title "$srq" with linespoints lw 1 lt 1, x title "Goal" lw 1 lt 3
EOF
`;
}
}
# 13. Get # of topologies sampled

my $n_topologies = `pickout n_topologies -n < Results/consensus`;

my $n_topologies_95;

open CONSENSUS, "Results/consensus";
while(my $line = <CONSENSUS>) {
    if ($line =~ /contains ([^ ]+) topologies/) {
	$n_topologies_95 = $1;
	last;
    }
}


# 14. Traceplots for scalar variables

my @var_names = ();
my %median = ();
my %CI_low = ();
my %CI_high = ();
my %ACT = ();
my %Ne = ();
my %Burnin = ();
    
if ("$parameters_file") 
{
    open VARS, $parameters_file;
    my $header = <VARS>;
    while ($header eq "" or substr($header,0,2) eq "# ") {
	$header = <VARS>;
    }
    chomp $header;
    @var_names = split(/\t/,$header);
    close VARS;
    
    open REPORT, "Results/Report";
    
    print "Generating trace-plots ... ";
    
    while (my $line = <REPORT>) {
	chomp $line;
	next if ($line eq "");
	
	if ($line =~ /\s+(.+) ~ (.+)\s+\((.+),(.+)\)/)
	{
	    my $var = $1;
	    $median{$var} = $2;
	    $CI_low{$var} = $3;
	    $CI_high{$var} = $4;
	    $line = <REPORT>;

	    $line =~ /t @ (.+)\s+Ne = ([^ ]+)\s+burnin = (Not Converged!|[^ ]+)/;
	    $ACT{$var} = $1;
	    $Ne{$var} = $2;
	    $Burnin{$var} = $3;
	}
	elsif ($line =~ /\s+(.+) = (.+)/) {
	    my $var = $1;
	    $median{$var} = $2;
	}
    }

    my $Nmax = 5000;

    for(my $i=1;$i<= $#var_names; $i++)
    {
	next if (more_recent_than("Results/$i.trace.png",$parameters_file));
	
	my $var = $var_names[$i];
	next if (!defined($CI_low{$var}));
	
	my $file1 = "Results/Work/T1.p.$i";
	if ($personality =~ "bali-phy.*") {
	    `stats-select iter '$var' --no-header < $parameters_file > $file1`;
	}
	elsif ($personality =~ "phylobayes.*") {
	    `stats-select time '$var' --no-header < $parameters_file > $file1`;
	}
	elsif ($personality =~ "beast.*")
	{
	    `stats-select state '$var' --no-header < $parameters_file > $file1`;
	}
	
	my $file2 = $file1.".2";
	
	my $N = $after_burnin;
	
	$N = 1000 if ($N > 1000);
	
	my $factor = ceil($after_burnin / $N);
	
	`subsample --skip=$burnin $factor < $file1 > $file2`;
	
	`gnuplot <<EOF
set terminal png size 800,600
set output "Results/$i.trace.png"
set key right bottom
set xlabel "Iteration"
set ylabel "$var"
plot '$file2' title '$var' with lines
EOF` if ($have_gnuplot);
    }

    print "done\n";
}

#------------------------- Print Index -----------------------#

my $p1_features = get_alignment_info("Results/P1-initial.fasta");

my $n_sequences = ${$p1_features}{"n_sequences"};

open INDEX,">Results/index.html";

my $title = "MCMC Post-hoc Analysis";
$title = $title . ": $n_sequences sequences" if defined($n_sequences);

print INDEX '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
';
print INDEX "<title>BAli-Phy: $title</title>\n";
print INDEX 
'    <style type="text/css">
      ol li {padding-bottom:0.5em}

      td {padding: 0.1em;}
      td {padding-left: 0.3em;}
      td {padding-right: 0.3em;}

#topbar {
	background-color: rgb(201,217,233);
	margin: 0;
	width: 99%;
	padding: 0.2em 0.2em 0.5em 0.2em; /* .5 is on the bottom */
	display: table;
	border: none; /* only needed for Netscape 4.x */
        width: 100%;
}
#topbar #menu {
	font-size: 90%;
	display: table-cell;
	text-align: right; 
}
#topbar #path {
	font-weight: bold;
	display: table-cell;
	text-align: left; 
	white-space: nowrap;
/*	whitespace: nowrap; only for Netscape 4.x, but causes invalidation */
}
      .backlit td {background: rgb(220,220,220);}

      h1 {font-size: 150%;}
      h2 {font-size: 130%; margin-bottom: 0.2em;}
      h3 {font-size: 110%; margin-top: 0.3em ; margin-bottom: 0.2em}

      ul {margin-top: 0.4em;}

      *[title] {cursor:help;}
      a[title] {vertical-align:top;color:#00f;font-size:70%; border-bottom:1px dotted;}
      .floating_picture {float:left;padding-left:0.5em;padding-right:0.5em;margin:0.5em;}    
      .r_floating_picture {float:right;padding-left:0.5em;padding-right:0.5em;margin:0.5em;}    
      .clear {clear:both;}    
    </style>
</head>
<body>
';

print INDEX '<p id="topbar"> 
   <span id="path">Sections:</span>
   <span id="menu">
    [<a href="#data">Data+Model</a>]
    [<a href="#analysis">Analysis</a>]
    [<a href="#alignment">Alignment</a>]
    [<a href="#topology">Phylogeny</a>]
    [<a href="#mixing">Mixing</a>]
    [<a href="#parameters">Parameters</a>]
   </span>
</p>
';


print INDEX "<h1>$title</h1>\n";
print INDEX '<object class="floating_picture" data="c50-tree.svg" type="image/svg+xml" height="200pt" width="200pt"></object>';
#print INDEX "<p>Samples were created by the following command line:</p>";
print INDEX "<p><b>command line:</b> $command</p>\n";
print INDEX "<p><b>directory:</b> $directory</p>\n";
foreach my $subdir (@subdirs)
{
    print INDEX "<p><b>subdirectory:</b> $subdir</p>\n";
}


print INDEX "<h2 style=\"clear:both\"><a name=\"data\">Data &amp; Model</a></h2>\n";
print INDEX "<table class=\"backlit\">\n";
print INDEX "<tr><th>Partition</th><th>Sequences</th><th>Lengths</th><th>Substitution&nbsp;Model</th><th>Indel&nbsp;Model</th></tr>\n";
for(my $p=0;$p<=$#partitions;$p++) 
{
    print INDEX "<tr>\n";
    print INDEX " <td>".($p+1)."</td>\n";
    print INDEX " <td>$partitions[$p]</td>\n";
    my $features = get_alignment_info("Results/P".($p+1)."-initial.fasta");
    my $min = $features->{'min_length'};
    my $max = $features->{'max_length'};
    my $alphabet = $alphabets[$p];
    print INDEX " <td>$min - $max $alphabet</td>\n";
    my $smodel = sanitize_smodel( $smodels[$smodel_indices[$p]] );
    print INDEX " <td>$smodel</td>\n";
    my $imodel ="none";
    $imodel = $imodels[$imodel_indices[$p]] if ($imodel_indices[$p] != -1);
    print INDEX " <td>$imodel</td>\n";
    print INDEX "</tr>\n";
}

print INDEX "</table>\n";

print INDEX "<h2><a name=\"analysis\">Analysis</a></h2>\n";
print INDEX '<table style="width:100%;">'."\n";

print INDEX "<tr>\n";
print INDEX "  <td>burn-in = $burnin samples</td>\n";
print INDEX "  <td>after burnin = $after_burnin samples</td>\n";
print INDEX "  <td>sub-sample = $subsample</td>\n" if ($subsample != 1);
print INDEX "</tr>\n";

print INDEX "<tr>\n";
print INDEX "  <td>$marginal_prob</td>\n";
print INDEX "</tr>\n";

print INDEX "<tr>\n";
print INDEX "  <td>Complete sample: $n_topologies topologies</td>\n";
print INDEX "  <td>95% Bayesian credible interval: $n_topologies_95 topologies</td>\n";
print INDEX "</tr>\n";

print INDEX "</table>\n";


print INDEX "<h2><a name=\"topology\">Phylogeny Distribution</a></h2>\n";

print INDEX '<object class="r_floating_picture" data="c-levels.svg" type="image/svg+xml" width="400pt" height="300pt"></object>';

print INDEX '<table>'."\n";
print INDEX "<tr><td>Partition support: <a href=\"consensus\">Summary</a></td></tr>\n";
print INDEX "<tr><td><span title=\"How many partitions are supported at each level of Posterior Log Odds (LOD)?\">Partition support graph:</span> <a href=\"c-levels.svg\">SVG</a></td></tr>\n";
print INDEX "</table>\n";

print INDEX "<table>\n";
for my $tree (@trees)
{
    my $name = $tree_name{$tree};
    print INDEX "<tr>";
    print INDEX "<td>$name</td>";
#    print INDEX "<td><a href=\"$tree.topology\">-L</a></td>";
    print INDEX "<td><a href=\"$tree.tree\">+L</a></td>";
    print INDEX "<td><a href=\"$tree-tree.pdf\">PDF</a></td>";
    print INDEX "<td><a href=\"$tree-tree.svg\">SVG</a></td>";

    if ($sub_partitions && (-f "Results/$tree.mtree" || -f "Results/$tree-mctree.svg" || -f "Results/$tree-mctree.pdf" )) {
	print INDEX "<td>MC Tree:</td>";
    }
    else {
	print INDEX "<td></td>"     
    }

    if ($sub_partitions && -f "Results/$tree.mtree") {
	print INDEX "<td><a href=\"$tree.mtree\">-L</a></td>"     
    }
    else {
	print INDEX "<td></td>"     
    }
    if ($sub_partitions && -f "Results/$tree-mctree.pdf") {
	print INDEX "<td><a href=\"$tree-mctree.pdf\">PDF</a></td>";
    }
    else {
	print INDEX "<td></td>"     
    }
    if ($sub_partitions && -f "Results/$tree-mctree.svg") {
	print INDEX "<td><a href=\"$tree-mctree.svg\">SVG</a></td>";
    }
    else {
	print INDEX "<td></td>"     
    }
    print INDEX "</tr>";
}
print INDEX "</table>\n";

print INDEX "<h2 class=\"clear\"><a name=\"alignment\">Alignment Distribution</a></h2>\n" if ($n_partitions > 0);

for(my $i=0;$i<$n_partitions;$i++) 
{
    my $p = $i+1;
    print INDEX "<h3>Partition $p</h3>\n";
    print INDEX "<table>\n";
    print INDEX "<tr>\n";
    print INDEX "<th></th>\n";
    print INDEX "<th></th>\n";
    print INDEX "<th></th>\n";
    print INDEX "<th title=\"Comparison of this alignment (top) to the WPD alignment (bottom)\">Diff</th>\n";
    print INDEX "<th></th>\n";
    print INDEX "<th style=\"padding-right:0.5em;padding-left:0.5em\" title=\"Percent identity of the most dissimilar sequences\">Min. %identity</th>\n";
    print INDEX "<th style=\"padding-right:0.5em;padding-left:0.5em\" title=\"Number of columns in the alignment\"># Sites</th>\n";
    print INDEX "<th style=\"padding-right:0.5em;padding-left:0.5em\" title=\"Number of invariant columns\">Constant</th>\n";
#    print INDEX "<th style=\"padding-right:0.5em;padding-left:0.5em\" title=\"Number of variant columns\">Variable</th>\n";
    print INDEX "<th title=\"Number of parsiomny-informative columns.\">Informative</th>\n";
    print INDEX "</tr>\n";
    for my $alignment (@alignments)
    {
	next if ($alignment !~ /^P$p-/);
	my $name = $alignment_names{$alignment};
	my $features = get_alignment_info("Results/$alignment.fasta");

	print INDEX "<tr>\n";
	print INDEX "<td>$name</td>\n";
	print INDEX "<td><a href=\"$alignment.fasta\">FASTA</a></td>\n";
	if (-f "Results/$alignment.html") {
	    print INDEX "<td><a href=\"$alignment.html\">HTML</a></td>\n";
	}
	else {
	    print INDEX "<td></td>\n";
	}
	if (-f "Results/$alignment-diff.html") {
	    print INDEX "<td><a href=\"$alignment-diff.html\">Diff</a></td>\n";
	}
	else {
	    print INDEX "<td></td>\n";
	}
	if (-f "Results/$alignment-AU.html") {
	    print INDEX "<td><a href=\"$alignment-AU.html\">AU</a></td>\n";
	}
	else {
	    print INDEX "<td></td>\n";
	}
	print INDEX "<td style=\"text-align: center\">${$features}{'min_p_identity'}%</td>\n";
	print INDEX "<td style=\"text-align: center\">${$features}{'length'}</td>\n";
	print INDEX "<td style=\"text-align: center\">${$features}{'n_const'} (${$features}{'p_const'}%)</td>\n";
#	print INDEX "<td style=\"text-align: center\">${$features}{'n_non-const'} (${$features}{'p_non-const'}%)</td>\n";
	print INDEX "<td style=\"text-align: center\">${$features}{'n_inform'} (${$features}{'p_inform'}%)</td>\n";
	print INDEX "</tr>\n";
    }
    print INDEX "</table>\n";
}

#print INDEX '<object class="r_floating_picture" data="partitions.SRQ.svg" type="image/svg+xml" height="200pt"></object>';
print INDEX '<img src="partitions.SRQ.png" class="r_floating_picture" alt="SRQ plot for support of each partition."/>';
#print INDEX '<object class="r_floating_picture" data="c50.SRQ.svg" type="image/svg+xml" height="200pt"></object>';
#print INDEX '<embed class="r_floating_picture" src="c50.SRQ.svg" type="image/svg+xml" height="200" />';
#print INDEX '<embed class="r_floating_picture" src="partitions.SRQ.svg" type="image/svg+xml" height="200" />';
print INDEX '<img src="c50.SRQ.png" class="r_floating_picture" alt="SRQ plot for supprt of 50% consensus tree."/>';
print INDEX "<h2><a name=\"mixing\">Mixing</a></h2>\n";

print INDEX "<ol>\n";
print INDEX "<li><a href=\"partitions.bs\">Partition uncertainty</a></li>\n";
for my $srq (@SRQ) {
    print INDEX "<li><a href=\"$srq.SRQ.png\">SRQ plot: $srq</a></li>\n";
}
print INDEX "</ol>\n";

my $burnin_before = get_value_from_file('Results/Report','min burnin <=');
$burnin_before = "Not Converged!" if ($burnin_before eq "Not");
print INDEX "<p><i>burn-in (scalar)</i> = $burnin_before</p>\n" if defined ($burnin_before);

print INDEX "<p><i>min Ne (scalar)</i> = ".get_value_from_file('Results/Report','Ne  >=')."</p\n";
print INDEX "<p><i>min Ne (partition)</i> = ".get_value_from_file('Results/partitions.bs','min Ne =')."</p>\n";

my $asdsf = get_value_from_file('Results/partitions.bs','ASDSF\[min=0.100\] =');
my $msdsf = get_value_from_file('Results/partitions.bs','MSDSF =');
print INDEX "<p><i>ASDSF</i> = $asdsf</p>\n" if defined ($asdsf);
print INDEX "<p><i>MSDSF</i> = $msdsf</p>\n" if defined ($msdsf);

my $psrf_80 = get_value_from_file('Results/Report','PSRF-80%CI <=');
my $psrf_rcf = get_value_from_file('Results/Report','PSRF-RCF <=');
print INDEX "<p><i>PSRF-80%CI</i> = $psrf_80</p>\n" if defined ($asdsf);
print INDEX "<p><i>PSRF-RCF</i> = $psrf_rcf</p>\n" if defined ($msdsf);

print INDEX '<p><a href="convergence-PP.pdf">Variation in split frequency estimates</a></p>'."\n";

if ($#var_names != -1) {
    print INDEX "<h2 class=\"clear\"><a name=\"parameters\">Scalar variables</a></h2>\n";

    print INDEX "<table>\n";
    print INDEX "<tr><th>Statistic</th><th>Median</th><th title=\"95% Bayesian Credible Interval\">95% BCI</th><th title=\"Auto-Correlation Time\">ACT</th><th title=\"Effective Sample Size\">Ne</th><th>burnin</th></tr>\n";
}
    
my $tne_string = `pickout -n Ne < Results/partitions.bs`;
my @tne_array = split(/\n/,$tne_string);
@tne_array = sort {$a <=> $b} @tne_array;
#my $min_tNe = $tne_array[0];
my $min_tNe = `pickout -n 'min Ne' < Results/partitions.bs`;

my @sne = sort {$a <=> $b} values(%Ne);
my $min_Ne = $sne[0];
print "\n";
print "NOTE: burnin (scalar) <= $burnin_before\n" if defined($burnin_before);
print "NOTE: min_Ne (scalar)    = $min_Ne\n" if defined($min_Ne);
print "NOTE: min_Ne (partition) = $min_tNe\n" if defined($min_tNe);
print "NOTE: ASDSF = $asdsf\n" if defined($asdsf);
print "NOTE: MSDSF = $msdsf\n" if defined($msdsf);
print "NOTE: PSRF-80%CI = $psrf_80\n" if defined($psrf_80);
print "NOTE: PSRF-RCF = $psrf_rcf\n" if defined($psrf_rcf);

for(my $i=1;$i <= $#var_names; $i++) 
{
    my $var = $var_names[$i];

    next if ($var eq "iter");
    next if (($var eq "time") && ($personality eq "phylobayes"));
    next if (($var eq "#treegen") && ($personality eq "phylobayes"));

    my $style = "";
    $style = 'style="font-style:italic"' if (!defined($CI_low{$var}));
    print INDEX "<tr $style>\n";
    print INDEX "<td>$var</td>\n";
    print INDEX "<td>$median{$var}</td>\n";
    if (defined($CI_low{$var})) {
	print INDEX "<td>($CI_low{$var}, $CI_high{$var})</td>\n";
	my $style = "";
	$style = ' style="color:red"' if ($Ne{$var} <= $min_Ne);
	print INDEX "<td $style>$ACT{$var}</td>\n";
	$style = "";
	$style = ' style="color:orange"' if ($Ne{$var} < 300);
	$style = ' style="color:red"' if ($Ne{$var} < 100);
	print INDEX "<td $style>$Ne{$var}</td>\n";
	$style = "";
	$style = ' style="color:red"' if ($Burnin{$var} eq "Not Converged!");
	print INDEX "<td $style>$Burnin{$var}</td>\n";
	print INDEX "<td><a href=\"$i.trace.png\">Trace</a></td>\n";
    }
    else {
	print INDEX "<td></td>";
	print INDEX "<td></td>";
	print INDEX "<td></td>";
	print INDEX "<td></td>";
    }
    print INDEX "</tr>\n";
}
print INDEX "</table>\n";


print INDEX "  </body>\n";
print INDEX "</html>\n";

sub Rexec
{
    return if (!$have_R);

    my $script = shift;

    my $args = shift;

    `R --slave --vanilla --args $args < $script`;
}

sub parse_command_line
{
    while ($#ARGV > -1) 
    {
	my $arg = shift @ARGV;
	if ($arg eq "clean" || $arg eq "--clean") {
	    do_cleanup();
	    exit;
	}
	elsif ($arg =~ /--burnin=(.+)/) {
	    $burnin = $1;
	}
	elsif ($arg =~ /--fast/) {
	    $speed = 2;
	}
	elsif ($arg =~ /--slow/) {
	    $speed = 0;
	}
	elsif ($arg =~ /--subsample=(.+)/) {
	    $subsample = $1;
	}
	elsif ($arg =~ /--prune=(.+)/) {
	    $prune = $1;
	}
	elsif ($arg =~ /--max=(.+)/) {
	    $max_iter = $1;
	}
	elsif ($arg =~ /--min-support=(.+)/) {
	    $min_support = $1;
	}
	elsif ($arg =~ /--muscle/) {
	    $muscle = 1;
	}
	elsif ($arg =~ /--probcons/) {
	    $probcons = 1;
	}
	elsif ($arg =~ /--mc-tree/) {
	    $sub_partitions=1;
	}
	elsif ($arg =~ /--treefile=(.+)/) {
	    $personality = "treefile";
	    $trees_file = $1;
	    if (! -e $trees_file) {
		print "Error: I can't find treefile '$trees_file'\n";
		exit(1);
	    }
	}    
	elsif ($arg =~ /^-.*/) {
	    print "Error: I don't recognize option '$arg'\n";
	    exit(1);
	}
	else
	{
	    push @directories, $arg;
	}
    }
    push @directories,"." if ($#directories == -1);
}


#----------------------------- SETUP 2 --------------------------#
sub determine_personality
{
    # quit if personality is already determined
    return if ($personality ne "");

    my $first_dir = $directories[0];
    
    if (-e "$first_dir/C1.out")
    {
	$personality = "bali-phy-2.1";
	$n_chains = get_header_attribute("$first_dir/C1.out","MPI_SIZE");
	$n_chains=1 if (!defined($n_chains));
	$personality = "bali-phy-2.1-heated" if ($n_chains > 1);
    }
    elsif (-e "$first_dir/1.out")
    {
	$personality = "bali-phy-2.0";
    }
    else {
	my @treelists = glob("$first_dir/*.treelist");
	my @beast_trees = glob("$first_dir/*.trees");
	if ($#treelists >= 0) 
	{
	    $personality = "phylobayes";
	}
	elsif ($#beast_trees >= 0) {
	    $personality = "beast";
	}
	else {
	    print "Error: No BAli-Phy, phylobayes, or BEAST files in directory '$first_dir'.\n";
	    exit(1);
	}
    }
}

sub check_file_exists
{
    my $filename = shift;
    if (! -e "$filename") {
	print "Error: I can't find file '$filename'\n";
	exit(1);
    }
    return $filename;
}

sub determine_input_files
{
    my $first_dir = $directories[0];

    if ($personality eq "bali-phy-2.1")
    {
	foreach my $directory (@directories)
	{
	    push @out_files, check_file_exists("$directory/C1.out");
	    push @tree_files, check_file_exists("$directory/C1.trees");
	    push @parameter_files, check_file_exists("$directory/C1.p");
	    # also add all the partition files... $partitions_samples[d][p]
	}
	$out_file = "$first_dir/C1.out";
	$trees_file = "$first_dir/C1.trees";
	$parameters_file = "$first_dir/C1.p";
	$MAP_file = "$first_dir/C1.MAP";
    }
    elsif ($personality eq "bali-phy-2.1-heated")
    {
	$out_file = "$first_dir/C1.out";
	$n_chains = get_header_attribute("MPI_SIZE");
	for(my $i=0;$i<$n_chains;$i++) {
	    push @out_files,"C$i.out" if (-e "C$i.out");
	    push @tree_files,"C$i.trees" if (-e "C$i.trees");
	}
    }
    elsif ($personality eq "bali-phy-2.0")
    {
	$out_file = check_file_exists("$first_dir/C1.out");
	$trees_file = check_file_exists("$first_dir/1.trees");
	$parameters_file = check_file_exists("$first_dir/1.p");
	
	@out_files = ( "$first_dir/1.out" );
	@tree_files = ( "$first_dir/1.trees" );
	$parameters_file = ( "$first_dir/1.p" );
	
	$MAP_file = ( "$first_dir/1.p" );
    }
    elsif ($personality eq "treefile")
    {
	@tree_files = ( $trees_file );
	$out_file = "";
	$parameters_file = "";
    }
    elsif ($personality eq "phylobayes")
    {
	print "Summarizing output files from phylobayes:\n";

	foreach my $directory (@directories)
	{
	    my @treelists = glob("$directory/*.treelist");
	    my @traces = glob("$directory/*.trace");

	    push @tree_files, check_file_exists("$treelists[0]");
	    push @parameter_files, check_file_exists("$traces[0]");
	}

	$trees_file = $tree_files[0];
	$parameters_file = $parameter_files[0];
    }
    elsif ($personality eq "beast")
    {
	print "Summarizing output files from BEAST:\n";
	my @beast_trees = glob("*.trees");
	$out_file = "";
	$trees_file = check_file_exists($beast_trees[0]);
	my $prefix = $trees_file;
	$prefix =~ s/.trees//;
	$parameters_file = check_file_exists("$prefix.log");
    }
    else {
	print "Error: unrecognized analysis of type '$personality'";
	exit(1);
    }
}

sub draw_trees
{
    return if (! $have_draw_tree);

    print " Drawing trees:  ";
    for my $cvalue (@tree_consensus_values)
    {
	my $value = $cvalue*100;
	
	my $tree = "c$value";

	# No node lengths???
	my $filename1 = "Results/$tree.tree";
	my $filename2 = "Results/$tree.mtree";
	
	if ($speed < 2)
	{
	    if (-e $filename2 && ! more_recent_than("Results/$tree-mctree.svg",$filename2)) {
		`draw-tree Results/$tree.mlengths --out=Results/$tree-mctree --output=svg --draw-clouds=only` if ($have_draw_tree);
	    }
	    if (-e $filename2 && ! more_recent_than("Results/$tree-mctree.pdf",$filename2)) {
		`draw-tree Results/$tree.mlengths --out=Results/$tree-mctree --draw-clouds=only` if ($have_draw_tree);
	    }
	}
	
#    Generate trees w/ node lengths.
	if (! more_recent_than("Results/$tree.ltree",$trees_file)) {
	    $prune_arg2 = "--prune $prune" if (defined($prune));
	    `tree-mean-lengths Results/$tree.tree --safe --show-node-lengths $max_arg $skip $subsample_string $prune_arg2 < $trees_file > Results/$tree.ltree`;
	}


	if (! more_recent_than("Results/$tree-tree.pdf",$filename1)) {
	    `cd Results ; draw-tree $tree.ltree --layout=equal-daylight --no-shade` if ($have_draw_tree);
	}
	
	if (! more_recent_than("Results/$tree-tree.svg",$filename1)) {
	    `cd Results ; draw-tree $tree.ltree --layout=equal-daylight --output=svg --no-shade` if ($have_draw_tree);
	}
	
	print "$tree ";
	my $prune_arg = "";
	$prune_arg = "--prune $prune" if defined($prune);
	
    }

    print "done.\n";
}

sub compute_wpd_alignments
{
    if ($personality =~ "bali-phy.*") {
	print "\nComputing WPD alignments... ";

	for(my $i=0;$i<$n_partitions;$i++) 
	{
	    next if ($imodel_indices[$i] == -1);
	
	    my $p = $i+1;
	    my $infile = $partition_samples[0][$i];
	    
	    my $name = "P$p-max";
	    if (! more_recent_than("Results/Work/$name-unordered.fasta",$infile) ||
		! more_recent_than("Results/Work/$name-unordered.fasta",$infile) ) {
		`cut-range --skip=$burnin $size_arg < $infile | alignment-max> Results/Work/$name-unordered.fasta`;
	    }
	    push @alignments,$name;
	    $alignment_names{$name} = "Best (WPD)";
	    push @AU_alignments,$name;
	}
	
	print "done.\n";
    }
}

sub compute_consensus_alignments
{
    print "Computing consensus alignments:\n";
    for(my $i=0;$i<$n_partitions;$i++)
    {
	next if ($imodel_indices[$i] == -1);

	my $p = $i+1;
	my $infile = $partition_samples[0][$i];
	
	print " Partition $p: ";
	for my $cvalue (@alignment_consensus_values) {
	    my $value = $cvalue*100;
	    my $name = "P$p-consensus-$value";
	    print "c$value ";
	    if (! more_recent_than("Results/Work/$name-unordered.fasta",$infile)) {
		`cut-range --skip=$burnin $size_arg < $infile | alignment-consensus --cutoff=$cvalue> Results/Work/$name-unordered.fasta`;
	    }
	    push @alignments,$name;
	    $alignment_names{$name} = "$value% consensus";
	}
	print "done.\n\n";
	push @AU_alignments,"P$p-consensus-10" if ($speed == 0);
    }
}

sub find_in_path
{
    my $file = shift;
    my $home = $ENV{'HOME'};

    my @dirs = split(':',$ENV{'PATH'});
    
    for my $dir (@dirs) {
	$dir =~ s/^~/$home/;
	if (-x "$dir/$file" ) {
	    return "$dir/$file";
	}
    }

    return undef;
}

sub is_in_path
{
    return 1 if (defined(find_in_path(@_)));
    return 0;
}

sub do_init
{
    mkdir "Results";
    mkdir "Results/Work";
}

sub do_cleanup
{
    rmdir_recursive("Results") if (-e "Results");
}

sub rmdir_recursive 
{
    my $dir = shift;
    local *DIR;

    opendir DIR, $dir or die "opendir $dir: $!";
    for (readdir DIR) {
	next if /^\.{1,2}$/;
	my $path = "$dir/$_";
	unlink $path if -f $path;
	rmdir_recursive($path) if -d $path;
    }
    closedir DIR;
    rmdir $dir or print "error - $!";
}

sub get_partitions
{
    return [] if ($personality !~ "bali-phy.*");

    my $file = shift;
    $file = $out_file if (!defined($file));

    local *FILE;

    open FILE, $out_file or die "Can't open $out_file!";

    my @partitions = ();

    while (my $line = <FILE>) 
    {
	if ($line =~ /data(.+) = (.+)/) {
	    my $filename = $2;
	    $filename =~ s/$home/~/;
	    push @partitions,$filename;
	}
	if ($line =~ /data = (.+)/) {
	    my $filename = $1;
	    $filename =~ s/$home/~/;
	    push @partitions,$filename;
	}
	last if ($line =~ /^iterations = 0/);
    }
    return [@partitions];
}

sub get_cmdline_attribute
{
    return "unknown" if ($personality !~ "bali-phy.*");
    my $attribute = shift;
    my $value;

    local *FILE;

    open FILE, $out_file or die "Can't open $out_file!";

    my @partitions = ();

    my $line = <FILE>;
    {
	if ($line =~ /--$attribute[ =]([^ ]*)$/) {
	    $value = $1;
	    last;
	}
	last if ($line =~ /^iterations = 0/);
    }
    close FILE;

    return $value;
}

sub get_header_attribute
{
    return "unknown" if ($personality !~ "bali-phy.*");
    my $filename = shift;
    my $attribute = shift;
    my $value;

    local *FILE;

    open FILE, $filename or die "Can't open $filename!";

    my @partitions = ();

    while (my $line = <FILE>) 
    {
	if ($line =~ /$attribute: (.*)$/) {
	    $value = $1;
	    last;
	}
	last if ($line =~ /^iterations = 0/);
    }
    close FILE;

    return $value;
}

sub get_value_from_file
{
    my $filename = shift;
    my $attribute = shift;

    my $value;

    local *FILE;

    open FILE, $filename or die "Can't open $filename!";

    my @partitions = ();

    while (my $line = <FILE>) 
    {
	if ($line =~ /$attribute ([^ ]*)($| )/) {
	    $value = $1;
	    last;
	}
    }
    close FILE;

    return $value;
}

sub get_header_attributes
{
    return ("unknown") if ($personality !~ "bali-phy.*");
    my $attribute = shift;
    my @filenames = @_;
    my @values;

    foreach my $filename (@filenames)
    {

	local *FILE;

	open FILE, $filename or die "Can't open $filename!";

	my @partitions = ();

	while (my $line = <FILE>) 
	{
	    if ($line =~ /$attribute: (.*)$/) {
		push @values, $1;
		last;
	    }
	    last if ($line =~ /^iterations = 0/);
	}
	close FILE;
    }

    return @values;
}

#Empirical(/home/bredelings/local/share/bali-phy/Data//wag.dat) 

sub sanitize_smodel
{
    my $smodel = shift;

    if ($smodel =~ m|(Empirical\(.*/(.*).dat\))|)
    {
	my $temp1 = $1;
	my $temp2 = $2;
	$temp2 =~ tr/a-z/A-Z/;
	
	$smodel =~ s/\Q$temp1/$temp2/;
    }

    return $smodel;
}

sub get_smodels
{
    return [] if ($personality !~ "bali-phy.*");

    local *FILE;

    open FILE, $out_file or die "Can't open $out_file!";

    my @smodels = ();

    while (my $line = <FILE>) 
    {
	if ($line =~ /subst model(.+) = (.+)/) {
	    push @smodels,$2;
	}
	if ($line =~ /subst model = (.+)/) {
	    push @smodels,$1;
	}
	last if ($line =~ /^iterations = 0/);
    }
    close FILE;

    return [@smodels];
}

sub get_imodels
{
    return [] if ($personality !~ "bali-phy.*");

    local *FILE;

    open FILE, $out_file or die "Can't open $out_file!";

    my @imodels = ();

    while (my $line = <FILE>) 
    {
	if ($line =~ /indel model(.+) = (.+)/) {
	    push @imodels,$2;
	}
	if ($line =~ /indel model = (.+)/) {
	    push @imodels,$1;
	}

	last if ($line =~ /^iterations = 0/);
    }
    close FILE;

    push @imodels, "none" if ($#imodels == -1);
    return [@imodels];
}

sub get_smodel_indices
{
    return [] if ($personality !~ "bali-phy.*");

    local *FILE;

    open FILE, $out_file or die "Can't open $out_file!";

    my @smodel_indices = ();

    while (my $line = <FILE>) 
    {
	if ($line =~ /smodel-index(.+) = (.+)/) {
	    push @smodel_indices,$2;
	}
	last if ($line =~ /^iterations = 0/);
    }
    close FILE;

    return [@smodel_indices];
}

sub get_imodel_indices
{
    return [] if ($personality !~ "bali-phy.*");

    local *FILE;

    open FILE, $out_file or die "Can't open $out_file!";

    my @imodel_indices = ();

    while (my $line = <FILE>) 
    {
	if ($line =~ /imodel-index(.+) = (.+)/) {
	    push @imodel_indices,$2;
	}
	last if ($line =~ /^iterations = 0/);
    }
    return [@imodel_indices];
}

sub get_alphabets
{
    return [] if ($personality !~ "bali-phy.*");

    local *FILE;

    open FILE, $out_file or die "Can't open $out_file!";

    my @alphabets = ();

    while (my $line = <FILE>) 
    {
	if ($line =~ /alphabet(.+) = (.+)/) {
	    push @alphabets,$2;
	}
	if ($line =~ /alphabet = (.+)/) {
	    push @alphabets,$1;
	}

	last if ($line =~ /^iterations = 0/);
    }
    close FILE;

    return @alphabets;
}

sub get_n_lines
{
    my $filename = shift;

    local *FILE;
  
    open FILE, $filename;

    my $n_lines = 0;

    while (<FILE>) {
	$n_lines++;
    }

    return $n_lines;
}

sub get_n_iterations
{
    return get_n_lines($trees_file)-1;
}

sub more_recent_than
{
    my $filename1 = shift;
    my $filename2 = shift;

    die "I can't open '$filename2'" if (! -f $filename2);
    return 0 if (! -f $filename1);

    my $age1 = -M $filename1;
    my $age2 = -M $filename2;

    return 1 if ($age1 <= $age2);
    return 0;
}

sub more_recent_than_all_of
{
    my $filename1 = shift;
    my $temp = shift;
    my @filenames2 = @$temp;

    foreach my $filename2 (@filenames2) {
	return 0 if (!more_recent_than($filename1,$filename2));
    }

    return 1;
}

sub get_prev_burnin
{
    my $prev_burnin;
    $prev_burnin = `cat Results/burnin` if (-e "Results/burnin");
    return $prev_burnin;
}

sub record_burnin
{
    open BURN,">Results/burnin";
    print BURN $burnin;
    close BURN;
}

sub get_alignment_info 
{
    return {} if ($personality !~ "bali-phy.*");

    my $filename = shift;
    open INFO,"alignment-info $filename |";

    my %features = ();

    my $indels = 0;
    while(my $line=<INFO>) {
	if ($line =~ /Alphabet: (.*)$/) {
	    $features{"alphabet"} = $1;
	}
	if ($line =~ /Alignment: (.+) columns of (.+) sequences/) 
	{
	    $features{"length"} = $1;
	    $features{"n_sequences"} = $2;
	}
	if ($line =~ /sequence lengths: ([^ ]+)-([^ ]+)/) {
	    $features{"min_length"} = $1;
	    $features{"max_length"} = $2;
	}
	if ($line =~ m|w/  indels|) {
	    $indels = 1;
	}
	next if ($indels == 0);

	if ($line =~ / const.: ([^ ]+) \(([^ ]+)\%\)/) {
	    $features{"n_const"} = $1;
	    $features{"p_const"} = $2;
	}
	if ($line =~ /non-const.: ([^ ]+) \(([^ ]+)\%\)/) {
	    $features{"n_non-const"} = $1;
	    $features{"p_non-const"} = $2;
	}
	if ($line =~ /inform.: ([^ ]+) \(([^ ]+)\%\)/) {
	    $features{"n_inform"} = $1;
	    $features{"p_inform"} = $2;
	}
	if ($line =~ / ([^ ]+)% minimum sequence identity/){
	    $features{"min_p_identity"} = $1;
	}
    }
    return {%features};
}

sub tooltip
{
    my $text = shift;
    return "<a title=\"$text\">?</a>";
}

sub get_consensus_arg
{
    my $suffix = shift;
    my $levels = shift;
    my @pairs = @$levels;
    for my $level (@pairs)
    {
	my $filename = $level*100;
	$filename = "Results/c$filename.".$suffix;
	$level = "$level:$filename";
    }
    return join(',',@pairs);
}

