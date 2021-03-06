/*
   Copyright (C) 2010 Benjamin Redelings

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

///
/// \file parameters.H
///
/// \brief This file defines the generic Probability_Model class.
///

#ifndef PROBABILITY_MODEL_H
#define PROBABILITY_MODEL_H

#include <map>
#include <string>
#include "model.H"
#include "mytypes.H"

/// A Model with member functions for probability
class Probability_Model: virtual public Model
{
public:
  /// An object for key-value pairs.
  std::map<std::string,double> keys;

  virtual Probability_Model* clone() const =0;

  // The prior, likelihood, and probability
  //  (We inherit 'this->prior()' from class Model)
  virtual efloat_t probability() const {return prior() * likelihood();}
  virtual efloat_t likelihood() const {return 1.0;}

  virtual efloat_t heated_prior() const {return prior();}
  virtual efloat_t heated_likelihood() const {return likelihood();}
  virtual efloat_t heated_probability() const {return heated_prior() * heated_likelihood();}
};


#endif
