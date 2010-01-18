/*
   Copyright (C) 2004-2010 Benjamin Redelings

This file is part of BAli-Phy.

BAli-Phy is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation; either version 2, or (at your option) any later
version.

BAli-Phy is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
for more details.

You should have received a copy of the GNU General Public License
along with BAli-Phy; see the file COPYING.  If not see
<http://www.gnu.org/licenses/>.  */

#include "setup-mcmc.H"
#include "sample.H"
#include "alignment-util.H"
#include "alignment-constraint.H"

///
/// \file   setup-mcmc.C
/// \brief  Provides routines to create default transition kernels and start a Markov chain.
///
/// The function do_sampling( ) creates transition kernel for known parameter names.
/// It then starts the Markov chain for the MCMC run and runs it for a specified
/// number of iterations.
///
/// \author Benjamin Redelings
/// 

using boost::program_options::variables_map;
using boost::dynamic_bitset;
using std::vector;
using std::string;
using std::ostream;


/// \brief Check if the model M has a parameter called name
///
/// \param M      The model
/// \param name   A parameter name
///
bool has_parameter(const Model& M, const string& name)
{
  for(int i=0;i<M.parameters().size();i++)
    if (M.parameter_name(i) == name)
      return true;
  return false;
}

/// \brief Check if the string s1 matches a pattern s2
///
/// \param s1   The string
/// \param s2   The pattern
///
bool match(const string& s1, const string& s2)
{
  if (s2.size() and s2[s2.size()-1] == '*') {
    int L = s2.size() - 1;
    if (L > s1.size()) return false;
    return (s1.substr(0,L) == s2.substr(0,L));
  }
  else
    return s1 == s2;
}


/// \brief Find the index of model parameters that match the pattern name
///
/// \param M      The model
/// \param name   The pattern
///
vector<int> parameters_with_extension(const Model& M, string name)
{
  bool complete_match = false;
  if (name.size() and name[0] == '^') {
    complete_match = true;
    name = name.substr(1,name.size()-1);
  }

  vector<int> indices;

  const vector<string> path2 = split(name,"::");

  if (not path2.size()) return indices;

  for(int i=0;i<M.n_parameters();i++)
  {
    vector<string> path1 = split(M.parameter_name(i),"::");

    if (not path2[0].size()) 
      path1.erase(path1.begin());
    else if (path2.size() > path1.size())
      continue;
    else if (not complete_match)
    {
      int n = path1.size() - path2.size();
      path1.erase(path1.begin(),path1.begin() + n);
    }

    if (not match(path1.back(),path2.back())) continue;

    path1.pop_back();

    vector<string> temp = path2;
    temp.pop_back();

    if (path1 == temp) indices.push_back(i);
  }
  return indices;
}

/// \brief Add a Metropolis-Hastings sub-move for parameter name to M
///
/// \param P       The model that contains the parameters
/// \param p       The proposal function
/// \param name    The name of the parameter to create a move for
/// \param pname   The name of the proposal width for this move
/// \param sigma   A default proposal width, in case the user didn't specify one
/// \param M       The group of moves to which to add the newly-created sub-move
///
void add_MH_move(Parameters& P,const Proposal_Fn& p, const string& name, const string& pname,double sigma, MCMC::MoveAll& M)
{
  if (name.size() and name[name.size()-1] == '*')
  {
    vector<int> indices = parameters_with_extension(P,name);
    vector<string> names;
    for(int i=0;i<indices.size();i++)
      names.push_back(P.parameter_name(indices[i]));

    if (names.empty()) return;

    set_if_undef(P.keys, pname, sigma);
    Proposal2 move_mu(p, names, vector<string>(1,pname), P);

    M.add(1, MCMC::MH_Move(move_mu,string("MH_sample_")+name));
  }
  else {
    vector<int> indices = parameters_with_extension(P,name);
    for(int i=0;i<indices.size();i++) 
      if (not P.fixed(indices[i])) {
	set_if_undef(P.keys, pname, sigma);
	Proposal2 move_mu(p, P.parameter_name(indices[i]), vector<string>(1,pname), P);
	M.add(1, MCMC::MH_Move(move_mu,string("MH_sample_")+P.parameter_name(indices[i])));
      }
  }
}


/// \brief Add a 1-D slice-sampling sub-move for parameter name to M
///
/// \param P             The model that contains the parameters
/// \param name          The name of the parameter to create a move for
/// \param pname         The name of the slice window width for this move
/// \param lower_bound   Is there a lower bound on the range of the parameter.
/// \param lower         The lower bound
/// \param upper_bound   Is there a upper bound on the range of the parameter.
/// \param uppper        The upper bound
/// \param M             The group of moves to which to add the newly-created sub-move
///
void add_slice_moves(Parameters& P, const string& name, 
		     const string& pname, double W,
		     bool lower_bound, double lower,
		     bool upper_bound, double upper,
		     MCMC::MoveAll& M)
{
  vector<int> indices = parameters_with_extension(P,name);
  for(int i=0;i<indices.size();i++) 
  {
    if (P.fixed(indices[i])) continue;

    // Use W as default window size of "pname" is not set.
    set_if_undef(P.keys, pname, W);
    W = P.keys[pname];

    M.add(1, 
	  MCMC::Slice_Move(string("slice_sample_")+P.parameter_name(indices[i]),
			   indices[i],
			   lower_bound,lower,upper_bound,upper,W)
	  );
  }
}

/// \brief Add a 1-D slice-sampling sub-move for parameter name to M on a transformed scale
///
/// \param P             The model that contains the parameters
/// \param name          The name of the parameter to create a move for
/// \param pname         The name of the slice window width for this move
/// \param lower_bound   Is there a lower bound on the range of the parameter.
/// \param lower         The lower bound
/// \param upper_bound   Is there a upper bound on the range of the parameter.
/// \param uppper        The upper bound
/// \param M             The group of moves to which to add the newly-created sub-move
/// \param f1            The function from the parameter's scale to the transformed scale.
/// \param f2            The inverse of f1
///
void add_slice_moves(Parameters& P, const string& name, 
		     const string& pname, double W,
		     bool lower_bound, double lower,
		     bool upper_bound, double upper,
		     MCMC::MoveAll& M,
		     double(&f1)(double),
		     double(&f2)(double)
		     )
{
  vector<int> indices = parameters_with_extension(P,name);
  for(int i=0;i<indices.size();i++) 
  {
    if (P.fixed(indices[i])) continue;

    // Use W as default window size of "pname" is not set.
    set_if_undef(P.keys, pname, W);
    W = P.keys[pname];

    M.add(1, 
	  MCMC::Slice_Move(string("slice_sample_")+P.parameter_name(indices[i]),
			   indices[i],
			   lower_bound,lower,upper_bound,upper,W,f1,f2)
	  );
  }
}

//FIXME - how to make a number of variants with certain things fixed, for burn-in?
// 0. Get an initial tree estimate using NJ or something? (as an option...)
// 1. First estimate tree and parameters with alignment fixed.
// 2. Then allow the alignment to change.

/// \brief Construct Metropolis-Hastings moves for scalar numeric parameters with a corresponding slice move
///
/// \param P   The model and state.
///
MCMC::MoveAll get_parameter_MH_moves(Parameters& P)
{
  MCMC::MoveAll MH_moves("parameters:MH");

  add_MH_move(P, log_scaled(between(-20,20,shift_cauchy)),    "mu",             "mu_scale_sigma",     0.6,  MH_moves);
  for(int i=0;i<P.n_branch_means();i++)
    add_MH_move(P, log_scaled(between(-20,20,shift_cauchy)),    "mu"+convertToString(i+1),             "mu_scale_sigma",     0.6,  MH_moves);

  add_MH_move(P, log_scaled(between(-20,20,shift_cauchy)),    "HKY::kappa",     "kappa_scale_sigma",  0.3,  MH_moves);
  add_MH_move(P, log_scaled(between(-20,20,shift_cauchy)),    "rho",     "rho_scale_sigma",  0.2,  MH_moves);
  add_MH_move(P, log_scaled(between(-20,20,shift_cauchy)),    "TN::kappa(pur)", "kappa_scale_sigma",  0.3,  MH_moves);
  add_MH_move(P, log_scaled(between(-20,20,shift_cauchy)),    "TN::kappa(pyr)", "kappa_scale_sigma",  0.3,  MH_moves);
  add_MH_move(P, log_scaled(shift_cauchy),    "M0::omega",  "omega_scale_sigma",  0.3,  MH_moves);
  add_MH_move(P, log_scaled(more_than(0,shift_cauchy)),
	                                        "M2::omega",  "omega_scale_sigma",  0.3,  MH_moves);
  add_MH_move(P, between(0,1,shift_cauchy),   "INV::p",         "INV::p_shift_sigma", 0.03, MH_moves);
  add_MH_move(P, between(0,1,shift_cauchy),   "f",              "f_shift_sigma",      0.1,  MH_moves);
  add_MH_move(P, between(0,1,shift_cauchy),   "g",              "g_shift_sigma",      0.1,  MH_moves);
  add_MH_move(P, between(0,1,shift_cauchy),   "h",              "h_shift_sigma",      0.1,  MH_moves);
  add_MH_move(P, log_scaled(shift_cauchy),    "beta::mu",       "beta::mu_scale_sigma",     0.2,  MH_moves);
  add_MH_move(P, log_scaled(shift_cauchy),    "gamma::sigma/mu","gamma::sigma_scale_sigma",  0.25, MH_moves);
  add_MH_move(P, log_scaled(shift_cauchy),    "beta::sigma/mu", "beta::sigma_scale_sigma",  0.25, MH_moves);
  add_MH_move(P, log_scaled(shift_cauchy),    "log-normal::sigma/mu","log-normal::sigma_scale_sigma",  0.25, MH_moves);
  MH_moves.add(4,MCMC::SingleMove(scale_means_only,
				   "scale_means_only","mean")
		      );

  
  add_MH_move(P, shift_delta,                 "delta",       "lambda_shift_sigma",     0.35, MH_moves);
  add_MH_move(P, less_than(0,shift_cauchy), "lambda",      "lambda_shift_sigma",    0.35, MH_moves);
  add_MH_move(P, shift_epsilon,               "epsilon",     "epsilon_shift_sigma",   0.30, MH_moves);

  add_MH_move(P, between(0,1,shift_cauchy), "invariant",   "invariant_shift_sigma", 0.15, MH_moves);

  return MH_moves;
}

/// \brief Construct 1-D slice-sampling moves for (some) scalar numeric parameters
///
/// \param P   The model and state.
///
MCMC::MoveAll get_parameter_slice_moves(Parameters& P)
{
  MCMC::MoveAll slice_moves("parameters:slice");

  // scale parameters
  add_slice_moves(P, "mu",      "mu_slice_window",    0.3, true,0,false,0,slice_moves);
  for(int i=0;i<P.n_branch_means();i++)
    add_slice_moves(P, "mu"+convertToString(i+1),      "mu_slice_window",    0.3, true,0,false,0,slice_moves);

  // smodel parameters
  add_slice_moves(P, "HKY::kappa",      "kappa_slice_window",    0.3, true,0,false,0,slice_moves);
  add_slice_moves(P, "rho",      "rho_slice_window",    0.2, true,0,false,0,slice_moves);
  add_slice_moves(P, "TN::kappa(pur)",      "kappa_slice_window",    0.3, true,0,false,0,slice_moves);
  add_slice_moves(P, "TN::kappa(pyr)",      "kappa_slice_window",    0.3, true,0,false,0,slice_moves);
  add_slice_moves(P, "M0::omega",      "omega_slice_window",    0.3, true,0,false,0,slice_moves);
  add_slice_moves(P, "M2::omega",      "omega_slice_window",    0.3, true,0,false,0,slice_moves);
  add_slice_moves(P, "INV::p",         "INV::p_slice_window", 0.1, true,0,true,1,slice_moves);
  add_slice_moves(P, "f",      "f_slice_window",    0.1, true,0,true,1,slice_moves);
  add_slice_moves(P, "g",      "g_slice_window",    0.1, true,0,true,1,slice_moves);
  add_slice_moves(P, "h",      "h_slice_window",    0.1, true,0,true,1,slice_moves);
  add_slice_moves(P, "beta::mu",      "beta::mu_slice_window",    0.1, true,0,false,0,slice_moves);
  add_slice_moves(P, "gamma::sigma/mu",      "gamma::sigma_slice_window",    1.0, true,0,false,0,slice_moves);
  add_slice_moves(P, "beta::sigma/mu",      "beta::sigma_slice_window",    1.0, true,0,false,0,slice_moves);
  add_slice_moves(P, "log-normal::sigma/mu",      "log-normal::sigma_slice_window",    1.0, true,0,false,0,slice_moves);

  // imodel parameters
  add_slice_moves(P, "delta",      "lambda_slice_window",    1.0, false,0,false,0,slice_moves);
  add_slice_moves(P, "lambda",      "lambda_slice_window",    1.0, false,0,false,0,slice_moves);
  add_slice_moves(P, "epsilon",     "epsilon_slice_window",   1.0,
		  false,0,false,0,slice_moves,transform_epsilon,inverse_epsilon);

  return slice_moves;
}

/// \brief Construct dynamic programming moves to sample alignments.
///
/// \param P   The model and state.
///
MCMC::MoveAll get_alignment_moves(Parameters& P)
{
  // args for branch-based stuff
  vector<int> branches(P.T->n_branches());
  for(int i=0;i<branches.size();i++)
    branches[i] = i;

  // args for node-based stuff
  vector<int> internal_nodes;
  for(int i=P.T->n_leaves();i<P.T->n_nodes();i++)
    internal_nodes.push_back(i);

  using namespace MCMC;

  //----------------------- alignment -------------------------//
  MoveAll alignment_moves("alignment");

  //--------------- alignment::alignment_branch ---------------//
  MoveEach alignment_branch_moves("alignment_branch_master");
  alignment_branch_moves.add(1.0,
			     MoveArgSingle("sample_alignments","alignment:alignment_branch",
					   sample_alignments_one,
					   branches)
			     );
  if (P.T->n_leaves() >2) {
    alignment_branch_moves.add(0.15,MoveArgSingle("sample_tri","alignment:alignment_branch:nodes",
						 sample_tri_one,
						 branches)
			       );
    alignment_branch_moves.add(0.1,MoveArgSingle("sample_tri_branch","alignment:nodes:length",
						 sample_tri_branch_one,
						 branches)
			       ,false);
    alignment_branch_moves.add(0.1,MoveArgSingle("sample_tri_branch_aligned","alignment:nodes:length",
						 sample_tri_branch_type_one,
						 branches)
			       ,false);
  }
  alignment_moves.add(1, alignment_branch_moves, false);
  alignment_moves.add(1, SingleMove(walk_tree_sample_alignments, "walk_tree_sample_alignments","alignment:alignment_branch:nodes") );

  //---------- alignment::nodes_master (nodes_moves) ----------//
  MoveEach nodes_moves("nodes_master","alignment:nodes");
  if (P.T->n_leaves() >= 3)
    nodes_moves.add(10,MoveArgSingle("sample_node","alignment:nodes",
				   sample_node_move,
				   internal_nodes)
		   );
  if (P.T->n_leaves() >= 4)
    nodes_moves.add(1,MoveArgSingle("sample_two_nodes","alignment:nodes",
				   sample_two_nodes_move,
				   internal_nodes)
		   );

  int nodes_weight = (int)(loadvalue(P.keys,"nodes_weight",1.0)+0.5);

  alignment_moves.add(nodes_weight, nodes_moves);
 
  return alignment_moves;
}

/// \brief Construct moves to sample the tree
///
/// \param P   The model and state.
///
MCMC::MoveAll get_tree_moves(Parameters& P)
{
  // args for branch-based stuff
  vector<int> branches(P.T->n_branches());
  for(int i=0;i<branches.size();i++)
    branches[i] = i;

  // args for branch-based stuff
  vector<int> internal_branches;
  for(int i=P.T->n_leaves();i<P.T->n_branches();i++)
    internal_branches.push_back(i);

  using namespace MCMC;

  //-------------------- tree (tree_moves) --------------------//
  MoveAll tree_moves("tree");
  MoveAll topology_move("topology");
  MoveEach NNI_move("NNI");
  MoveOne SPR_move("SPR");

  bool has_imodel = (P.n_imodels() > 0);

  if (has_imodel)
    NNI_move.add(1,MoveArgSingle("three_way_NNI","alignment:nodes:topology",
				 three_way_topology_sample,
				 internal_branches)
		 );
  else
    NNI_move.add(1,MoveArgSingle("three_way_NNI","topology",
				 three_way_topology_sample,
				 internal_branches)
		 );

  NNI_move.add(1,MoveArgSingle("two_way_NNI","alignment:nodes:topology",
				    two_way_topology_sample,
				    internal_branches)
		    ,false
		    );

  //FIXME - doesn't yet deal with gaps=star
  if (has_imodel)
    NNI_move.add(0.025,MoveArgSingle("three_way_NNI_and_A","alignment:alignment_branch:nodes:topology",
				   three_way_topology_and_alignment_sample,
				     internal_branches)
		 ,false
		 );


  if (has_imodel) {
    SPR_move.add(1,SingleMove(sample_SPR_flat,"SPR_and_A_flat","topology:lengths:nodes:alignment:alignment_branch"));
    SPR_move.add(1,SingleMove(sample_SPR_nodes,"SPR_and_A_nodes","topology:lengths:nodes:alignment:alignment_branch"));
    SPR_move.add(10,SingleMove(sample_SPR_all,"SPR_and_A_all","topology:lengths:nodes:alignment:alignment_branch"));
  }
  else {
    SPR_move.add(1,SingleMove(sample_SPR_flat,"SPR_flat","topology:lengths"));
    SPR_move.add(1,SingleMove(sample_SPR_nodes,"SPR_and_A_nodes","topology:lengths"));
    SPR_move.add(10,SingleMove(sample_SPR_all,"SPR_and_A_all","topology:lengths"));
  }

  topology_move.add(1,NNI_move,false);
  topology_move.add(1,SPR_move);
  if (P.T->n_leaves() >3 and P.smodel_full_tree)
    tree_moves.add(1,topology_move);
  
  //-------------- tree::lengths (length_moves) -------------//
  MoveAll length_moves("lengths");
  MoveEach length_moves1("lengths1");

  length_moves1.add(1,MoveArgSingle("change_branch_length","lengths",
				   change_branch_length_move,
				   branches)
		   );
  length_moves1.add(1,MoveArgSingle("change_branch_length_multi","lengths",
				   change_branch_length_multi_move,
				   branches)
		   );
  if (P.smodel_full_tree)
    length_moves1.add(0.01,MoveArgSingle("change_branch_length_and_T","lengths:nodes:topology",
					change_branch_length_and_T,
					internal_branches)
		      );
  length_moves.add(1,length_moves1,false);
  // FIXME - Do we really want to do this, under slice sampling?
  length_moves.add(1,SingleMove(walk_tree_sample_branch_lengths,
				"walk_tree_sample_branch_lengths","lengths")
		   );

  tree_moves.add(1,length_moves);
  tree_moves.add(1,SingleMove(sample_NNI_and_branch_lengths,"NNI_and_lengths","topology:lengths"));

  return tree_moves;
}

/// \brief Construct Metropolis-Hastings moves for scalar numeric parameters without a corresponding slice move
///
/// \param P   The model and state.
///
MCMC::MoveAll get_parameter_MH_but_no_slice_moves(Parameters& P)
{
  using namespace MCMC;

  MoveAll parameter_moves("parameters");

  set_if_undef(P.keys,"pi_dirichlet_N",1.0);
  unsigned total_length = 0;
  for(int i=0;i<P.n_data_partitions();i++)
    total_length += max(sequence_lengths(*P[i].A, P.T->n_leaves()));
  P.keys["pi_dirichlet_N"] *= total_length;

  for(int s=0;s<=P.n_smodels();s++) 
  {
    string index = convertToString(s+1);
    string prefix = "^S" + index + "::";

    if (s==P.n_smodels())
      prefix = "^";

    add_MH_move(P, dirichlet_proposal,  prefix + "pi*",    "pi_dirichlet_N",      1,  parameter_moves);
    
    add_MH_move(P, dirichlet_proposal,  prefix + "INV::pi*",    "pi_dirichlet_N",      1,  parameter_moves);
    add_MH_move(P, dirichlet_proposal,  prefix + "VAR::pi*",    "pi_dirichlet_N",      1,  parameter_moves);

    set_if_undef(P.keys,"GTR_dirichlet_N",1.0);
    if (s==0) P.keys["GTR_dirichlet_N"] *= 100;
    add_MH_move(P, dirichlet_proposal,  prefix + "GTR::*", "GTR_dirichlet_N",     1,  parameter_moves);

    set_if_undef(P.keys,"v_dirichlet_N",1.0);
    if (s==0) P.keys["v_dirichlet_N"] *= total_length;
    add_MH_move(P, dirichlet_proposal,  prefix +  "v*", "v_dirichlet_N",     1,  parameter_moves);

    set_if_undef(P.keys,"b_dirichlet_N",1.0);
    if (s==0) P.keys["b_dirichlet_N"] *= total_length;
    add_MH_move(P, dirichlet_proposal,  prefix +  "b_*", "b_dirichlet_N",     1,  parameter_moves);

    set_if_undef(P.keys,"M2::f_dirichlet_N",1.0);
    if (s==0) P.keys["M2::f_dirichlet_N"] *= 10;
    add_MH_move(P, dirichlet_proposal,  prefix +  "M2::f*", "M2::f_dirichlet_N",     1,  parameter_moves);

    set_if_undef(P.keys,"M3::f_dirichlet_N",1.0);
    if (s==0) P.keys["M3::f_dirichlet_N"] *= 10;
    add_MH_move(P, dirichlet_proposal,   prefix + "M3::f*", "M3::f_dirichlet_N",     1,  parameter_moves);

    set_if_undef(P.keys,"multi::p_dirichlet_N",1.0);
    if (s==0) P.keys["multi::p_dirichlet_N"] *= 10;
    add_MH_move(P, dirichlet_proposal,   prefix + "multi::p*", "multi:p_dirichlet_N",     1,  parameter_moves);

    set_if_undef(P.keys,"DP::f_dirichlet_N",1.0);
    if (s==0) P.keys["DP::f_dirichlet_N"] *= 10;
    add_MH_move(P, dirichlet_proposal,   prefix + "DP::f*", "DP::f_dirichlet_N",     1,  parameter_moves);

    set_if_undef(P.keys,"DP::rate_dirichlet_N",1.0);
    //FIXME - this should probably be 20*#rate_categories...
    if (s==0) P.keys["DP::rate_dirichlet_N"] *= 10*10;
    add_MH_move(P, sorted(dirichlet_proposal), prefix + "DP::rate*", "DP::rate_dirichlet_N",     1,  parameter_moves);

    set_if_undef(P.keys,"Mixture::p_dirichlet_N",1.0);
    if (s==0) P.keys["Mixture::p_dirichlet_N"] *= 10*10;
    add_MH_move(P, dirichlet_proposal,         prefix + "Mixture::p*", "Mixture::p_dirichlet_N",     1,  parameter_moves);

    if (s >= P.n_smodels()) continue;

    // Handle multi-frequency models
    set_if_undef(P.keys,"MF::dirichlet_N",10.0);

    const alphabet& a = P.SModel(s).Alphabet();
    const int asize = a.size();

    for(int l=0;l<asize;l++) {
      string pname = prefix+ "a" + a.lookup(l) + "*";
      add_MH_move(P, dirichlet_proposal, pname, "MF::dirichlet_N",     1,  parameter_moves);
    }
  }

  // FIXME - we need a proposal that sorts after changing
  //         then we can un-hack the recalc function in smodel.C
  //         BUT, this assumes that we have the DP::rate* names in *numerical* order
  //          whereas we probably find them in *lexical* order....
  //          ... or creation order?  That might be OK for now! 


  for(int i=0;;i++) {
    string name = "M3::omega" + convertToString(i+1);
    if (not has_parameter(P,name))
      break;

    add_MH_move(P, log_scaled(shift_cauchy), name, "omega_scale_sigma", 1, parameter_moves);
    //    Proposal2 m(log_scaled(shift_cauchy), name, vector<string>(1,"omega_scale_sigma"), P);
    //    parameter_moves.add(1, MCMC::MH_Move(m,"sample_M3::omega"));
  }

  return parameter_moves;
}

/// \brief Create transition kernels and start a Markov chain
///
/// \param args            Contains command line arguments
/// \param P               The model and current state
/// \param max_iterations  The number of iterations to run (unless interrupted).
/// \param files           Files to log output into
///
void do_sampling(const variables_map& args,Parameters& P,long int max_iterations,
		 vector<ostream*>& files)
{
  using namespace MCMC;

  bool has_imodel = (P.n_imodels() > 0);

  //----------------------- alignment -------------------------//
  MoveAll alignment_moves = get_alignment_moves(P);

  //------------------------- tree ----------------------------//
  MoveAll tree_moves = get_tree_moves(P);

  //-------------- parameters (parameters_moves) --------------//
  MoveAll MH_but_no_slice_moves = get_parameter_MH_but_no_slice_moves(P);
  MoveAll slice_moves = get_parameter_slice_moves(P);
  MoveAll MH_moves = get_parameter_MH_moves(P);

  //------------------ Construct the sampler  -----------------//
  int subsample = args["subsample"].as<int>();

  // full sampler
  Sampler sampler("sampler");
  if (has_imodel)
    sampler.add(1,alignment_moves);
  sampler.add(2,tree_moves);

  // FIXME - We certainly don't want to do MH_sample_mu[i] O(branches) times
  // - It does call the likelihood function, doesn't it?
  // FIXME - Perhaps we want to do MH_sample_epsilon more times, though.
  // FIXME -   But we should do that by weighting the epsilon moves, above.
  // FIXME -   However, it is probably not so important to resample most parameters in a way that is interleaved with stuff... (?)
  // FIXME -   Certainly, we aren't going to be interleaved with branches, anyway!
  sampler.add(5 + log(P.T->n_branches()), MH_but_no_slice_moves);
  if (P.keys["enable_MH_sampling"] > 0.5)
    sampler.add(5 + log(P.T->n_branches()),MH_moves);
  else
    sampler.add(1,MH_moves);
  // Question: how are these moves intermixed with the other ones?

  if (P.keys["disable_slice_sampling"] < 0.5)
    sampler.add(1,slice_moves);

  vector<string> disable;
  vector<string> enable;
  if (args.count("disable"))
    disable = split(args["disable"].as<string>(),',');
  if (args.count("enable"))
    enable = split(args["enable"].as<string>(),',');
  
  for(int i=0;i<disable.size();i++)
    sampler.disable(disable[i]);
  
  for(int i=0;i<enable.size();i++)
    sampler.enable(enable[i]);

  //------------------ Report status before starting MCMC -------------------//
  
  ostream& s_out = *files[0];
  ostream& s_trees = *files[2];
  ostream& s_parameters = *files[3];
  ostream& s_map = *files[4];
  
  sampler.show_enabled(s_out);
  s_out<<"\n";

  int total_c = 0;
  for(int i=0;i<P.n_data_partitions();i++)
    total_c += P[i].alignment_constraint.size1();

  if (total_c > 0)
    std::cerr<<"Using "<<total_c<<" constraints.\n";

  //FIXME - partition

  for(int i=0;i<P.n_data_partitions();i++) {
    dynamic_bitset<> s2 = constraint_satisfied(P[i].alignment_constraint,*P[i].A);
    dynamic_bitset<> s1(s2.size());
    report_constraints(s1,s2);
  } 

  // before we do this, just run 20 iterations of a sampler that keeps the alignment fixed
  // - first, we need a way to change the tree on a sampler that has internal node sequences?
  // - well, this should be exactly the -t sampler.
  // - but then how do we copy stuff over?

  sampler.go(P,subsample,max_iterations,s_out,s_trees,s_parameters,s_map,files);
}
