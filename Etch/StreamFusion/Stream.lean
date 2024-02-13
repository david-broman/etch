/-
This file implements a prototype of indexed stream fusion,
  an optimization to speed up programs that manipulate (nested) associative arrays.

Authors: Scott Kovach
-/

/- Ideally we would use the same Stream definition from SkipStream, which doesn't critically use Classical.
   For now, we redefine valid/ready to return Bool -/

/- General notes:
  Stream.fold generates the top-level loop.
    For performance, we want this to include no calls to lean_apply_[n] and minimal allocations
      (so far there are still some tuples allocated for multiplication states)
    Some care is needed to ensure everything is inlined.

  Stream.mul is the key combinator. it multiplies the non-zero values of two streams.

  The choice of inline vs macro_inline is not intentional anywhere except for `Stream.next`, where macro_inline seems to be necessary
-/

/- TODOs: see github wiki -/

import Mathlib.Data.Prod.Lex
import Init.Data.Array.Basic
import Std.Data.RBMap
import Std.Data.HashMap
import Mathlib.Data.ByteArray

open Std (RBMap HashMap)

-- hack: redefine these instances to ensure they are inlined (see instDecidableLeToLEToPreorderToPartialOrder)
section
variable [LinearOrder α]
@[inline] instance (a b : α) : Decidable (a < b) := LinearOrder.decidableLT a b
@[inline] instance (a b : α) : Decidable (a ≤ b) := LinearOrder.decidableLE a b
@[inline] instance (a b : α) : Decidable (a = b) := LinearOrder.decidableEq a b
end

namespace Std

@[inline]
def RBMap.toFn [Ord ι] [Zero α] (map : RBMap ι α Ord.compare) : ι → α := fun i => map.find? i |>.getD 0

@[inline]
def HashMap.modifyD [BEq α] [Hashable α] [Zero β] (self : HashMap α β) (a : α) (f : β → β) : HashMap α β :=
  self.insert a (f $ self.findD a 0)

@[inline]
def HashMap.modifyD' [BEq α] [Hashable α] [Zero β] (self : HashMap α β) (a : α) (f : β → β) : HashMap α β :=
  if self.contains a then self.modify a (fun _ => f) else self.insert a (f 0)

@[inline]
def RBMap.modifyD [Zero β] (self : RBMap α β h) (a : α) (f : β → β) : RBMap α β h :=
  self.insert a (f $ self.findD a 0)
  --self.alter a (fun | none => some 0 | some a => some (f a))
end Std

namespace Etch.Verification

structure Stream (ι : Type) (α : Type u) where
  σ : Type
  valid : σ → Bool
  ready : {x // valid x} → Bool
  seek  : {x // valid x} → ι ×ₗ Bool → σ
  index : {x // valid x} → ι
  value : {x // ready x} → α

-- stream plus a state
structure SStream (ι : Type) (α : Type u) extends Stream ι α where
  q : σ

infixr:25 " →ₛ " => SStream

namespace Stream
variable {ι : Type} {α : Type _} [Mul α] [LinearOrder ι]
variable (s : Stream ι α)

@[simps, inline]
def contract (s : Stream ι α) : Stream Unit α where
  σ := s.σ
  valid := s.valid
  ready := s.ready
  index := default
  value := s.value
  seek q := fun ((), r) => s.seek q (s.index q, r)

-- For some reason, this definition *definitely* needs to be macro_inline for performance.
-- Everything else I have checked is safe at @[inline].
@[macro_inline]
def next (s : Stream ι α) (q : s.σ) (h : s.valid q = true) (ready : Bool) : s.σ :=
  let q := ⟨q, h⟩; s.seek q (s.index q, ready)

-- todo: use Bounded class, remove partial

/- (Important def) Converting a Stream into data
   This definition follows the same inline/specialize pattern as Array.forInUnsafe
-/
@[inline] partial def fold (f : β → ι → α → β) (s : Stream ι α) (q : s.σ) (acc : β) : β :=
  let rec @[specialize] go f
      (valid : s.σ → Bool) (ready : (x : s.σ) → valid x → Bool)
      (index : (x : s.σ) → valid x → ι) (value : (x : s.σ) → (h : valid x) → ready x h → α)
      (next : (x : s.σ) → valid x → Bool → s.σ)
      (acc : β) (q : s.σ) :=
    if hv : valid q then
      if hr : ready q hv
           then go f valid ready index value next (f acc (index q hv) (value q hv hr)) (next q hv true)
           else go f valid ready index value next acc (next q hv false)
    else acc
  go f s.valid (fun q h => s.ready ⟨q,h⟩) (fun q h => s.index ⟨q,h⟩) (fun q v r => s.value ⟨⟨q,v⟩,r⟩) s.next
     acc q

end Stream

def Vec α n := { x : Array α // x.size = n }
def Vec.map (v : Vec α n) (f : α → β) : Vec β n := ⟨v.1.map f, by have := Array.size_map f v.1; simp [*, v.2]⟩
def Vec.push (l : Vec α n) (v : α) : Vec α (n+1) :=
  ⟨l.1.push v, by have := Array.size_push l.1 v; simp only [this, l.2]⟩

structure Level (ι : Type) (α : Type u) (n : ℕ) where
  is : Vec ι n
  vs : Vec α n

def Level.push (l : Level ι α n) (i : ι) (v : α) : Level ι α (n+1) :=
  ⟨l.is.push i, l.vs.push v⟩

def FloatVec n := { x : FloatArray // x.size = n }

namespace SStream

variable {ι : Type} [LinearOrder ι] {α : Type u}

@[inline]
def map (f : α → β) (s : SStream ι α) : SStream ι β := { s with value := f ∘ s.value}

variable [Inhabited ι]

/- Converting data into a SStream -/
def zero : SStream ι α where
  σ := Unit; q := (); valid _ := false; ready _ := false;
  index _ := default; value := fun ⟨_, h⟩ => nomatch h;
  seek _ _ := ();

instance : Zero (SStream ι α) := ⟨SStream.zero⟩

-- deprecated
@[inline]
def ofArray (l : Array (ι × α)) : SStream ι α where
  σ := ℕ
  q := 0
  valid q := q < l.size
  ready _ := true
  index q := (l[q.1]'(by simpa using q.2)).1
  value := fun ⟨q, _⟩ => (l[q.1]'(by simpa using q.2)).2
  seek q := fun ⟨j, r⟩ =>
    let i := (l[q.1]'(by simpa using q.2)).fst
    if r then if i ≤ j then q+1 else q
         else if i < j then q+1 else q

@[inline]
def ofArrayPair (is : Array ι) (vs : Array α) (eq : is.size = vs.size) : SStream ι α where
  σ := ℕ
  q := 0
  valid q := q < is.size
  ready _ := true
  index q := (is[q.1]'(by simpa using q.2))
  value := fun ⟨q, _⟩ => (vs[q.1]'(eq ▸ (by simpa using q.2)))
  seek q := fun ⟨j, r⟩ =>
    let i := (is[q.1]'(by simpa using q.2))
    if r then if i ≤ j then q+1 else q
         else if i < j then q+1 else q

-- not tested yet
--@[macro_inline]
--def ofFloatArray (is : Array ι) (vs : FloatArray) (eq : is.size = vs.size) : SStream ι Float where
--  σ := ℕ
--  q := 0
--  valid q := q < is.size
--  ready q := q < is.size
--  index k h := (is[k]'(by simpa using h))
--  value k h := (vs[k]'(eq ▸ (by simpa using h)))
--  seek q hq := fun ⟨j, r⟩ =>
--    let i := is[q]'(by simpa using hq)
--    if r then if i ≤ j then q+1 else q
--         else if i < j then q+1 else q

-- Used as a base case for ToStream/OfStream
class Scalar (α : Type u)
instance : Scalar ℕ := ⟨⟩
instance : Scalar Float := ⟨⟩
instance : Scalar Bool := ⟨⟩

class ToStream (α : Type u) (β : outParam $ Type v) where
  stream : α → β

instance [Scalar α] : ToStream α α := ⟨id⟩

instance {α β} [ToStream α β] : ToStream  (Array (ℕ × α)) (ℕ →ₛ β) where
  stream := map ToStream.stream ∘ ofArray

instance {α β} [ToStream α β] : ToStream  (Level ι α n) (ι →ₛ β) where
  stream := map ToStream.stream ∘ (fun ⟨⟨is, _⟩, ⟨vs, _⟩⟩ => ofArrayPair is vs (by simp [*]))

--instance : ToStream  (Vec ι n × FloatVec n) (SStream ι Float) where
--  stream := fun (a, b) => ofFloatArray a.1 b.1 (a.property.trans b.property.symm)

@[inline] def fold (f : β → ι → α → β) (s : SStream ι α) (acc : β) : β := s.toStream.fold f s.q acc

@[inline] def toArrayPair (s : SStream ι α) : Array ι × Array α → Array ι × Array α :=
  s.fold (fun (a,b) i v => ⟨a.push i, b.push v⟩)

-- not used yet
--@[inline] def toLevel (s : SStream ι α) : (n : ℕ) × (Level ι α n) :=
--  s.fold (fun ⟨_, l⟩ i v => ⟨_, l.push i v⟩) s.q ⟨0, ⟨⟨#[], rfl⟩, ⟨#[], rfl⟩⟩⟩
--@[inline] def toArrayPair (s : SStream ι α) : Array ι × Array α :=
--  let ⟨_, l⟩ : (n : _) × Level ι α n := s.fold (fun ⟨_, l⟩ i v => ⟨_, l.push i v⟩) ⟨0, ⟨⟨#[], rfl⟩, ⟨#[], rfl⟩⟩⟩ s.q
--  (l.1.1, l.2.1)

class OfStream (α : Type u) (β : Type v) where
  eval : α → β → β

section eval
open OfStream

instance [Scalar α] [Add α] : OfStream α α := ⟨(.+.)⟩

/- Note!! recursive application of `eval` needs to occur outside of any enclosing functions to achieve full inlining
   (see bad examples below)
-/

instance [OfStream β β'] : OfStream (SStream Unit β) β' where
  eval := fold (fun a _ b => b a) ∘ map eval
  -- bad: fold (fun a _ b => OfStream.eval b a)

-- Doesn't support update of previous indices; assumes fully formed value is
--   inserted at each step (so pass 0 to recursive eval)
instance [OfStream β β'] [Zero β']: OfStream (ι →ₛ β) (Array ι × Array β') where
  eval := toArrayPair ∘ map (eval . 0)

-- BEq issue without writing (@HashMap ...)
instance [BEq ι] [Hashable ι] [OfStream α β] [Zero β] : OfStream (ι →ₛ α) (@HashMap ι β inferInstance inferInstance) where
  eval := fold HashMap.modifyD ∘ map eval

instance [OfStream α β] [Zero β] : OfStream (ι →ₛ α) (RBMap ι β Ord.compare) where
  eval := fold RBMap.modifyD ∘ map eval
  -- bad: eval := fold fun m k => m.modifyD k ∘ eval

end eval

@[inline] def expand (a : α) : ι → α := fun _ => a

@[inline]
def contract (a : SStream ι α) : SStream Unit α := {
  a.toStream.contract with
  q := a.q
}

@[inline]
def contract2 : (ℕ →ₛ ℕ →ₛ α) → Unit →ₛ Unit →ₛ α := contract ∘ SStream.map contract

end SStream

open Etch.Verification.SStream
open ToStream

@[inline] def eval [Zero β] [OfStream α β] : α → β := (OfStream.eval . 0)

instance : EmptyCollection (Array α × Array β) := ⟨#[], #[]⟩
instance [EmptyCollection α] : Zero α := ⟨{}⟩

abbrev Map a [Ord a] b := RBMap a b Ord.compare
abbrev ArrayMap a b := Array a × Array b

end Etch.Verification
