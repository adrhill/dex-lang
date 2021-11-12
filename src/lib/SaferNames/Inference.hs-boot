-- Copyright 2021 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

module SaferNames.Inference (trySynthDictBlock) where

import SaferNames.Name
import SaferNames.Syntax

trySynthDictBlock :: (Fallible1 m, BindingsReader m) => Type n -> m n (Block n)
