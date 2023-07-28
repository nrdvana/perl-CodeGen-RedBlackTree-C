package Lang::Generate::RedBlackTree::C;
use v5.26;
use experimental 'signatures';
use warnings;
use Carp;
use Config;

# ABSTRACT: Generate C code for custom Red/Black Trees
our $VERSION; # VERSION

=head1 SYNOPSIS

  Lang::Generate::RedBlackTree::C->new(%options)
    ->write_api('foo.h')
    ->write_impl('foo.c')
    ->write_wrapper(
      'sometype-rb.h',
      obj_t => 'SomeType',
      node => 'NodeFieldName',  # struct SomeType { rbtree_node_t NodeFieldName; }
      cmp => 'CompareFunc'      # int CompareFunc(SomeType *a, SomeType *b);
   )
    ->write_wrapper(
      'sometype-rb.h',
      obj_t => SomeType',
      node => 'NodeField2',
      key_t => 'const char*', key => 'KeyField',
      cmp => 'strcmp'
   );

=head1 DESCRIPTION

This module writes customizable Red/Black Tree algorithms as C source code.
While these sorts of things could be done with C header macros, I've decided
that is really a massive waste of time and wrote it as a perl script instead.

=cut

sub new {
   my $class= shift;
   my %args= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]}
      : !(@_&1)? @_
      : croak "Invalid arguments";
   # check for unknown args
   for (keys %args) {
      $class->can($_) or croak "Invalid attribute $_";
   }
   bless \%args, $class;
}

=head1 ATTRIBUTES

=head2 namespace

For C output, this prefixes each function and data type with a string, such as "rbtree_".

=head2 cmp

The algorithm that will be sued for comparing nodes to determine their sort order.

=over

=item numeric

Numeric comparison of keys using "<" and ">" operators.

=item relative

Keys will be placement within a numeric domain, and stored relative to the parent node
such that they recalculate when the tree rotates, and a segment of the tree can be shifted
in O(log(n)) time.

=item strcmp

Keys will be pointers, compared by passing them to strcmp.  Default key_type will be
C<< const char* >>.

=item memcmp

Keys must be fixed-length arrays, or pointers to fixed-length arrays, and will be compared with
memcmp.

=item callback

Each time nodes need compared, it will invoke a callback.

=back

=head2 key_type

Declare the key type, which will then be part of the node.  Don't declare this if you use
C<< cmp => 'callback' >> and don't require a 'key' field in the node, such as if your key
is found in the user data.

=cut

sub namespace      { $_[0]{namespace} || 'rbtree_' }
sub cmp            { $_[0]{cmp} || 'callback' }
sub key_type       { $_[0]{key_type} || undef }

=head2 node_type

The type name of the red/black node, C<< ${namespace}_node_t >> by default.
If it starts with C<"struct "> literal struct types will be used throughout,
else it will be declared as a typedef for the struct.

=head2 node_data_type

The type name of user-data the node references.  This must be a pointer.
The default is C<< void* >>, resulting in generic code that you can cast as needed.

=head2 node_offset

This enables the option of using a red/black node that is contained within a larger struct at
a known offset.  (The pointers in the R/B node still point to other inner nodes rather than
the outer struct)  Set this attribute to a byte offset, or a field name of C<node_data_type>.

Example:

  struct my_struct {
    ...
    rbtree_node_t node;
    ...
  };

  #  node_data_type => 'struct my_struct'
  #  node_offset    => 'node',

When using this feature, L</node_field_data> is unused, shrinking the node struct by one pointer.

=head2 node_fields

This is a hashref for overriding the names of the fields within the node.

  {                # typedef struct rbtree_node {
    left   => ..., #   struct rbtree_node * ${node_fields}{left};
    right  => ..., #   struct rbtree_node * ${node_fields}{right};
    parent => ..., #   struct rbtree_node * ${node_fields}{parent};
    color  => ..., #   size_t ${node_fields}{color} : 1;
    count  => ..., #   size_t ${node_fields}{count} : ${size_t_bits_minus_one};
    key    => ..., #   ${key_type} ${node_fields}{key};
    data   => ..., #   ${node_data_type} ${node_fields}{data};
  }                # } ${node_type};

Note that if you use the 'count' feature, you can declare it as 

=cut

sub node_type         { $_[0]{node_type} || undef }
sub node_data_type    { $_[0]{node_data_type} || undef }
sub node_offset       { $_[0]{node_offset} // undef }
sub node_fields       { $_[0]{node_fields} ||= {} }

sub size_type         { $_[0]{size_type} || $Config{sizetype} }
sub size_size         { $_[0]{size_size} || $Config{sizesize} }

=head2 with_count

Include the node-count feature which allows you to find the Nth node in the tree in O(log(n))
time.  This comes at a very small performance cost when modifying the tree.

=cut

sub with_count        { $_[0]{with_count} // 1 }

sub _node_pointer_type($self) {
   my $typename= $self->node_type || $self->namespace . 'node_t';
   # If starts with '*', then it is a typedef that already indicates a pointer.
   return $typename =~ /^[*]/? $typename : $typename . '*';
}

sub _if($cond, @items) {
   return $cond? @items : ();
}
sub _pad_to_same_len {
   my $max= List::Util::max(map length, grep defined, @_);
   $_ .= ' 'x($max - length) for grep defined, @_;
}
sub _node_type_decl($self) {
   my ($is_typedef, $struct_name, $typedef_varname);
   my $node_ptr_t= $self->_node_pointer_type;
   if ($node_ptr_t =~ /^struct (\w+)/) {
      $is_typedef= 0;
      $struct_name= $1;
   } else {
      $is_typedef= 1;
      $struct_name= $self->namespace . 'node';
      $typedef_varname= ($node_ptr_t =~ /[*]$/)
         ? substr($node_ptr_t, 0, -1)
         : '*'.$node_ptr_t;
   }
   my $key_t= $self->key_type;
   my $data_t= $self->node_data_type // 'void*';
   my ($size_t, $size_sz)= ($self->size_type, $self->size_size);
   my $has_data= !defined $self->node_offset;
   my $f_n= sub($name) { $self->node_fields->{$name} // $name };
   _pad_to_same_len($size_t, $node_ptr_t, $key_t, $data_t, $key_t, $data_t);
   return join "\n",
      _if( $is_typedef,              "struct $struct_name;" ),
      _if( $is_typedef,              "typedef struct $struct_name $typedef_varname;" ),
                                     "struct $struct_name {",
                                     "  $node_ptr_t ${\ $f_n->('left') };",
                                     "  $node_ptr_t ${\ $f_n->('right') };",
                                     "  $node_ptr_t ${\ $f_n->('parent') };",
      _if( $has_data,                "  $data_t ${\ $f_n->('data') };" ),
                                     "  $size_t ${\ $f_n->('color') } : 1;",
      _if( $self->with_count,        "  $size_t ${\ $f_n->('count') } : @{[ $size_sz * 8 - 1 ]};" ),
      _if( defined $self->key_type,  "  $key_t ${\ $f_n->('key') };" ),
                                     "};",
      '';
}

1;

__END__
sub header_fname  { $_[0]{header_fname} || do { my $x= $_[0]->namespace; $x =~ s/_$//; $x.'.h' } }
sub impl_fname    { $_[0]{impl_fname}   || do { my $x= $_[0]->namespace; $x =~ s/_$//; $x.'.c' } }

sub node_type     { $_[0]{node_type} || $_[0]->namespace.'node_t' }
sub api_decl      { defined $_[0]{api_decl}? $_[0]{api_decl} : 'extern' }
sub with_index    { defined $_[0]{with_index}?  $_[0]{with_index} : 1 }
sub with_relkeys  { defined $_[0]{with_relkeys}? $_[0]{with_relkeys} : 0 }
sub with_remove   { defined $_[0]{with_remove}? $_[0]{with_delete} : 1 }
sub with_clear    { defined $_[0]{with_clear}?  $_[0]{with_clear} : 1 }
sub with_check    { defined $_[0]{with_check}?  $_[0]{with_check} : 1 }
sub with_cmp_ctx  { defined $_[0]{with_cmp_ctx}?$_[0]{with_cmp_ctx} : 1 }
sub use_typedefs  { $_[0]{use_typedefs} }
sub timestamp     { my @t= gmtime; sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5]+1900, @t[4,3,2,1,0] }
sub size_type     { $_[0]{size_type} ||= $Config{sizetype} }
sub size_size     { $_[0]{size_size} ||= $Config{sizesize} }

sub write_api {
   my ($self, $dest)= @_;
   $self->{header}= $dest if $dest;
   my $ns= $self->namespace;
   my $include_guard= uc($dest);
   $include_guard =~ s/\W/_/g;
   $include_guard =~ s/^_+//;
   my $nd= $self->node_type;
   my $cmp_ctx_decl= !$self->with_cmp_ctx? '' : "void *ctx, ";
   my $api= 'extern';
   my $src= <<"END";
/* Auto-Generated by @{[ ref $self ]} version @{[ $self->VERSION ]} on @{[ $self->timestamp ]} */

#ifndef $include_guard
#define $include_guard

#include <stdbool.h>
#include <stddef.h>

/**
 * Red/Black tree node.  Nodes point to other nodes, so pointer math is
 * needed to reach the data paired with the node.
 */
typedef struct ${ns}node {
   struct ${ns}node *left, *right, *parent;
   @{[ $self->size_type ]} color: 1, count: @{[ $self->size_size * 8 - 1 ]};
} $nd;

typedef int (*${ns}compare_fn)(${cmp_ctx_decl}void *a, void *b);

#define ${ns}node_is_in_tree(node) ((bool) (node)->count)

/* Initialize a tree */
$api void ${ns}init_tree( $nd *root_sentinel, $nd *leaf_sentinel );

/* Returns previous node in conceptual sorted list of nodes, or NULL */
$api $nd *${ns}node_prev( $nd *node );

/* Returns next node in conceptual sorted list of nodes, or NULL */
$api $nd *${ns}node_next( $nd *node );

/* Returns right-most child of this node, or NULL */
$api $nd *${ns}node_right_leaf( $nd *node );

/* Returns left-most child of this node, or NULL */
$api $nd *${ns}node_left_leaf( $nd *node );

/* Returns the root-sentinel of the tree this node belongs to, or NULL */
$api $nd *${ns}node_rootsentinel( $nd *node );

/* Add a node to a tree */
$api bool ${ns}node_insert( $nd *hint, $nd *node, ${ns}compare_fn cmp_fn, ${cmp_ctx_decl}int cmp_pointer_ofs );

$api $nd * ${ns}find_nearest( $nd *node, void *goal,
   int(*cmp_fn)(${cmp_ctx_decl}void *a, void *b), ${cmp_ctx_decl}int cmp_pointer_ofs,
   int *cmp_result );

/* Find a node matching or close to 'goal'.  Pass NULL for answers that aren't needed.
 * Returns true for an exact match (cmp==0) and false for anything else.
 */
$api bool ${ns}find_all( $nd *node, void *goal, ${ns}compare_fn cmp_fn, ${cmp_ctx_decl}int cmp_pointer_ofs,
   $nd **result_first, $nd **result_last, size_t *result_count );
END

   $src .= <<"END" if $self->with_index;

/* Returns index of a node within the tree, as if the tree were a sorted array.
 * In other words, returns the number of nodes with a key less than this node.
 */
$api size_t ${ns}node_index( $nd *node );

/* Returns Nth child of a node, or NULL */
$api $nd *${ns}node_child_at_index( $nd *node, size_t index );

END

   $src .= <<"END" if $self->with_remove;

/* Remove a node from the tree */
$api void ${ns}node_prune( $nd *node );

END

   $src .= <<"END" if $self->with_clear;

/* Remove all nodes from the tree, and optionally run a function on each */
$api void ${ns}clear( $nd *root_sentinel, void (*destructor)(void *obj, void *opaque), int obj_ofs, void *opaque );

END
   $src .= <<"END" if $self->with_check;
/* Check tree for internal validity */
#define @{[ uc $ns ]}INVALID_ROOT     1
#define @{[ uc $ns ]}INVALID_SENTINEL 2
#define @{[ uc $ns ]}INVALID_NODE     4
#define @{[ uc $ns ]}INVALID_COUNT    8
#define @{[ uc $ns ]}INVALID_COLOR   16
#define @{[ uc $ns ]}INVALID_ORDER   32
$api int ${ns}check_structure( $nd *node, ${ns}compare_fn cmp_fn, ${cmp_ctx_decl}int cmp_pointer_ofs );

END
   $src .= "\n#endif /* $include_guard */\n";
   $self->_append($dest, $src);
   return $self;
}

sub write_impl {
   my ($self, $dest)= @_;
   my $ns= $self->namespace;
   my $nd= $self->node_type;
   my ($cmp_ctx_decl, $cmp_ctx_arg)= !$self->with_cmp_ctx? ('', '')
      : ( "void *ctx, ", "ctx, ");
   my $src= <<"END";
/* Auto-Generated by @{[ ref $self ]} version @{[ $self->VERSION ]} on @{[ $self->timestamp ]} */

/*
Credits:

  Intrest in red/black trees was inspired by Dr. John Franco, and his animated
    red/black tree java applet.
  http://www.ececs.uc.edu/~franco/C321/html/RedBlack/redblack.html

  The node insertion code was written in a joint effort with Anthony Deeter,
    as a class project.

  The red/black deletion algorithm was derived from the deletion patterns in
   "Fundamentals of Sequential and Parallel Algorithms",
    by Dr. Kenneth A. Berman and Dr. Jerome L. Paul

  I also got the sentinel node idea from this book.

*/

#include "@{[ $self->header ]}"
#include <assert.h>

#define IS_BLACK(node)         (!(node)->color)
#define IS_RED(node)           ((node)->color)
#define NODE_IS_IN_TREE(node)  ((node)->count != 0)
#define SET_COLOR_BLACK(node)  ((node)->color= 0)
#define SET_COLOR_RED(node)    ((node)->color= 1)
#define COPY_COLOR(dest,src)   ((dest)->color= (src)->color)
#define GET_COUNT(node)        ((node)->count)
#define SET_COUNT(node,val)    ((node)->count= (val))
#define ADD_COUNT(node,val)    ((node)->count+= (val))
#define IS_SENTINEL(node)      (!(bool) (node)->count)
#define IS_ROOTSENTINEL(node)  (!(bool) (node)->parent)
#define NOT_SENTINEL(node)     ((bool) (node)->count)
#define NOT_ROOTSENTINEL(node) ((bool) (node)->parent)
#define PTR_OFS(node,ofs)      ((void*)(((char*)(void*)(node))+ofs))

static void Balance( $nd *current );
static void RotateRight( $nd *node );
static void RotateLeft( $nd *node );
static void PruneLeaf( $nd *node );
static void InsertAtLeaf( $nd *leaf, $nd *new_node, bool on_left);

void ${ns}init_tree( $nd *root_sentinel, $nd *leaf_sentinel ) {
   SET_COUNT(root_sentinel, 0);
   SET_COLOR_BLACK(leaf_sentinel);
   root_sentinel->parent= NULL;
   root_sentinel->left= leaf_sentinel;
   root_sentinel->right= leaf_sentinel;
   SET_COUNT(leaf_sentinel, 0);
   SET_COLOR_BLACK(leaf_sentinel);
   leaf_sentinel->left= leaf_sentinel;
   leaf_sentinel->right= leaf_sentinel;
   leaf_sentinel->parent= leaf_sentinel;
}

$nd *${ns}node_left_leaf( $nd *node ) {
   if (IS_SENTINEL(node)) return NULL;
   while (NOT_SENTINEL(node->left))
      node= node->left;
   return node;
}

$nd *${ns}node_right_leaf( $nd *node ) {
   if (IS_SENTINEL(node)) return NULL;
   while (NOT_SENTINEL(node->right))
      node= node->right;
   return node;
}

$nd *${ns}node_rootsentinel( $nd *node ) {
   while (node && node->parent)
      node= node->parent;
   // The node might not have been part of the tree, so make extra checks that
   // this is really a sentinel
   return node && node->right && node->right->right == node->right? node : NULL;
}

$nd *${ns}node_prev( $nd *node ) {
   if (IS_SENTINEL(node)) return NULL;
   // If we are not at a leaf, move to the right-most node
   //  in the tree to the left of this node.
   if (NOT_SENTINEL(node->left)) {
      node= node->left;
      while (NOT_SENTINEL(node->right))
         node= node->right;
      return node;
   }
   // Else walk up the tree until we see a parent node to the left
   else {
      $nd *parent= node->parent;
      while (parent->left == node) {
         node= parent;
         parent= parent->parent;
         // Check for root_sentinel
         if (!parent) return NULL;
      }
      return parent;
   }
}

$nd *${ns}node_next( $nd *node ) {
   if (IS_SENTINEL(node)) return NULL;
   // If we are not at a leaf, move to the left-most node
   //  in the tree to the right of this node.
   if (NOT_SENTINEL(node->right)) {
      node= node->right;
      while (NOT_SENTINEL(node->left))
         node= node->left;
      return node;
   }
   // Else walk up the tree until we see a parent node to the right
   else {
      $nd *parent= node->parent;
      assert(parent);
      while (parent->right == node) {
         assert(parent != parent->parent);
         node= parent;
         parent= node->parent;
      }
      // Check for the root_sentinel
      if (!parent->parent) return NULL;
      return parent;
   }
}

/** Simple find algorithm.
 * This function looks for the nearest node to the requested key, returning the node and
 * the final value of the compare function which indicates whether this is the node equal to,
 * before, or after the requested key.
 */
$nd * ${ns}find_nearest($nd *node, void *goal,
   int(*compare)(${cmp_ctx_decl}void *a,void *b), ${cmp_ctx_decl}int cmp_ptr_ofs,
   int *last_cmp_out
) {
   $nd *nearest= NULL, *test;
   int count, cmp= 0;
   
   if (IS_ROOTSENTINEL(node))
      node= node->left;

   while (NOT_SENTINEL(node)) {
      nearest= node;
      cmp= compare( ${cmp_ctx_arg}goal, PTR_OFS(node,cmp_ptr_ofs) );
      if      (cmp<0) node= node->left;
      else if (cmp>0) node= node->right;
      else break;
   }
   if (nearest && last_cmp_out)
      *last_cmp_out= cmp;
   return nearest;
}

/** Find-all algorithm.
 * This function not only finds a node, but can find the nearest node to the one requested, finds the number of
 * matching nodes, and gets the first and last node so the matches can be iterated.
 */
bool ${ns}find_all($nd *node, void* goal,
   int(*compare)(${cmp_ctx_decl}void *a,void *b), ${cmp_ctx_decl}int cmp_ptr_ofs,
   $nd **result_first, $nd **result_last, size_t *result_count
) {
   $nd *nearest= NULL, *first, *last, *test;
   size_t count;
   int cmp;
   
   if (IS_ROOTSENTINEL(node))
      node= node->left;

   while (NOT_SENTINEL(node)) {
      nearest= node;
      cmp= compare( ${cmp_ctx_arg}goal, PTR_OFS(node,cmp_ptr_ofs) );
      if      (cmp<0) node= node->left;
      else if (cmp>0) node= node->right;
      else break;
   }
   if (IS_SENTINEL(node)) {
      /* no matches. Look up neighbor node if requested. */
      if (result_first)
         *result_first= nearest && cmp < 0? ${ns}node_prev(nearest) : nearest;
      if (result_last)
         *result_last=  nearest && cmp > 0? ${ns}node_next(nearest) : nearest;
      if (result_count) *result_count= 0;
      return false;
   }
   // we've found the head of the tree the matches will be found in
   count= 1;
   if (result_first || result_count) {
      // Search the left tree for the first match
      first= node;
      test= first->left;
      while (NOT_SENTINEL(test)) {
         cmp= compare( ${cmp_ctx_arg}goal, PTR_OFS(test,cmp_ptr_ofs) );
         if (cmp == 0) {
            first= test;
            count+= 1 + GET_COUNT(test->right);
            test= test->left;
         }
         else /* cmp > 0 */
            test= test->right;
      }
      if (result_first) *result_first= first;
   }
   if (result_last || result_count) {
      // Search the right tree for the last match
      last= node;
      test= last->right;
      while (NOT_SENTINEL(test)) {
         cmp= compare( ${cmp_ctx_arg}goal, PTR_OFS(test,cmp_ptr_ofs) );
         if (cmp == 0) {
            last= test;
            count+= 1 + GET_COUNT(test->left);
            test= test->right;
         }
         else /* cmp < 0 */
            test= test->left;
      }
      if (result_last) *result_last= last;
      if (result_count) *result_count= count;
   }
   return true;
}

/* Insert a new object into the tree.  The initial node is called 'hint' because if the new node
 * isn't a child of hint, this will backtrack up the tree to find the actual insertion point.
 */
bool ${ns}node_insert( $nd *hint, $nd *node, int(*compare)(${cmp_ctx_decl}void *a, void *b), ${cmp_ctx_decl}int cmp_ptr_ofs) {
   // Can't insert node if it is already in the tree
   if (NODE_IS_IN_TREE(node))
      return false;
   // check for first node scenario
   if (IS_ROOTSENTINEL(hint)) {
      if (IS_SENTINEL(hint->left)) {
         hint->left= node;
         node->parent= hint;
         node->left= hint->right; // tree's leaf sentinel
         node->right= hint->right;
         SET_COUNT(node, 1);
         SET_COLOR_BLACK(node);
         return true;
      }
      else
         hint= hint->left;
   }
   // else traverse hint until leaf
   int cmp;
   bool leftmost= true, rightmost= true;
   $nd *pos= hint, *next, *parent;
   while (1) {
      cmp= compare(${cmp_ctx_arg}PTR_OFS(node,cmp_ptr_ofs), PTR_OFS(pos,cmp_ptr_ofs) );
      if (cmp < 0) {
         rightmost= false;
         next= pos->left;
      } else {
         leftmost= false;
         next= pos->right;
      }
      if (IS_SENTINEL(next))
         break;
      pos= next;
   }
   // If the original hint was not the root of the tree, and cmp indicate the same direction 
   // as leftmost or rightmost, then backtrack and see if we're completely in the wrong spot.
   if (NOT_ROOTSENTINEL(hint->parent) && (cmp < 0? leftmost : rightmost)) {
      // we are the leftmost child of hint, so if there is a parent to the left,
      // key needs to not compare less else we have to start over.
      parent= hint->parent;
      while (1) {
         if ((cmp < 0? parent->right : parent->left) == hint) {
            if ((cmp < 0) == (compare(${cmp_ctx_arg}PTR_OFS(node,cmp_ptr_ofs), PTR_OFS(parent,cmp_ptr_ofs)) < 0)) {
               // Whoops.  Hint was wrong.  Should start over from root.
               while (NOT_ROOTSENTINEL(parent->parent))
                  parent= parent->parent;
               return ${ns}node_insert(parent, node, compare, ${cmp_ctx_arg}cmp_ptr_ofs);
            }
            else break; // we're fine afterall
         }
         else if (IS_ROOTSENTINEL(parent->parent))
            break; // we're fine afterall
         parent= parent->parent;
      }
   }
   if (cmp < 0)
      pos->left= node;
   else
      pos->right= node;
   node->parent= pos;
   // next is pointing to the leaf-sentinel for this tree after exiting loop above
   node->left= next;
   node->right= next;
   SET_COUNT(node, 1);
   SET_COLOR_RED(node);
   for (parent= pos; NOT_ROOTSENTINEL(parent); parent= parent->parent)
      ADD_COUNT(parent, 1);
   Balance(pos);
   // We've iterated to the root sentinel- so node->left is the head of the tree.
   // Set the tree's root to black
   SET_COLOR_BLACK(parent->left);
   return true;
}

void RotateRight( $nd *node ) {
   $nd *new_head= node->left;
   $nd *parent= node->parent;

   if (parent->right == node) parent->right= new_head;
   else parent->left= new_head;
   new_head->parent= parent;

   ADD_COUNT(node, -1 - GET_COUNT(new_head->left));
   ADD_COUNT(new_head, 1 + GET_COUNT(node->right));
   node->left= new_head->right;
   new_head->right->parent= node;

   new_head->right= node;
   node->parent= new_head;
}

void RotateLeft( $nd *node ) {
   $nd *new_head= node->right;
   $nd *parent= node->parent;

   if (parent->right == node) parent->right= new_head;
   else parent->left= new_head;
   new_head->parent= parent;

   ADD_COUNT(node, -1 - GET_COUNT(new_head->right));
   ADD_COUNT(new_head, 1 + GET_COUNT(node->left));
   node->right= new_head->left;
   new_head->left->parent= node;

   new_head->left= node;
   node->parent= new_head;
}

/** Re-balance a tree which has just had one element added.
 * current is the parent node of the node just added.  The child is red.
 *
 * node counts are *not* updated by this method.
 */
void Balance( $nd *current ) {
   // if current is a black node, no rotations needed
   while (IS_RED(current)) {
      // current is red, the imbalanced child is red, and parent is black.

      $nd *parent= current->parent;

      // if the current is on the right of the parent, the parent is to the left
      if (parent->right == current) {
         // if the sibling is also red, we can pull down the color black from the parent
         if (IS_RED(parent->left)) {
            SET_COLOR_BLACK(parent->left);
            SET_COLOR_BLACK(current);
            SET_COLOR_RED(parent);
            // jump twice up the tree. if current reaches the HeadSentinel (black node), the loop will stop
            current= parent->parent;
            continue;
         }
         // if the imbalance (red node) is on the left, and the parent is on the left,
         //  a "prep-slide" is needed. (see diagram)
         if (IS_RED(current->left))
            RotateRight( current );

         // Now we can do our left rotation to balance the tree.
         RotateLeft( parent );
         SET_COLOR_RED(parent);
         SET_COLOR_BLACK(parent->parent);
         return;
      }
      // else the parent is to the right
      else {
         // if the sibling is also red, we can pull down the color black from the parent
         if (IS_RED(parent->right)) {
            SET_COLOR_BLACK(parent->right);
            SET_COLOR_BLACK(current);
            SET_COLOR_RED(parent);
            // jump twice up the tree. if current reaches the HeadSentinel (black node), the loop will stop
            current= parent->parent;
            continue;
         }
         // if the imbalance (red node) is on the right, and the parent is on the right,
         //  a "prep-slide" is needed. (see diagram)
         if (IS_RED(current->right))
            RotateLeft( current );

         // Now we can do our right rotation to balance the tree.
         RotateRight( parent );
         SET_COLOR_RED(parent);
         SET_COLOR_BLACK(parent->parent);
         return;
      }
   }
   // note that we should now set the root node to be black.
   // but the caller does this anyway.
   return;
}

END

   $src .= <<"END" if $self->with_index;

size_t ${ns}node_index( $nd *node ) {
   int left_count= GET_COUNT(node->left);
   $nd *prev= node;
   node= node->parent;
   while (NOT_SENTINEL(node)) {
      if (node->right == prev)
         left_count += GET_COUNT(node->left)+1;
      prev= node;
      node= node->parent;
   }
   return left_count;
}

/** Find the Nth node in the tree, indexed from 0, from the left to right.
 * This operates by looking at the count of the left subtree, to descend down to the Nth element.
 */
$nd *${ns}node_child_at_index( $nd *node, size_t index ) {
   if (index >= GET_COUNT(node))
      return NULL;
   while (index != GET_COUNT(node->left)) {
      if (index < GET_COUNT(node->left))
         node= node->left;
      else {
         index -= GET_COUNT(node->left)+1;
         node= node->right;
      }
   }
   return node;
}
END

   $src .= <<"END" if $self->with_remove;

/** Prune a node from anywhere in the tree.
 * If the node is a leaf, it can be removed easily.  Otherwise we must swap the node for a leaf node
 * with an adjacent key value, and then remove from the position of that leaf.
 *
 * This function *does* update node counts.
 */
void ${ns}node_prune( $nd *current ) {
   $nd *temp, *successor;
   if (GET_COUNT(current) == 0)
      return;

   // If this is a leaf node (or almost a leaf) we can just prune it
   if (IS_SENTINEL(current->left) || IS_SENTINEL(current->right))
      PruneLeaf(current);

   // Otherwise we need a successor.  We are guaranteed to have one because
   //  the current node has 2 children.
   else {
      // pick from the largest subtree
      successor= (GET_COUNT(current->left) > GET_COUNT(current->right))?
         ${ns}node_prev( current )
         : ${ns}node_next( current );
      PruneLeaf( successor );

      // now exchange the successor for the current node
      temp= current->right;
      successor->right= temp;
      temp->parent= successor;

      temp= current->left;
      successor->left= temp;
      temp->parent= successor;

      temp= current->parent;
      successor->parent= temp;
      if (temp->left == current) temp->left= successor; else temp->right= successor;
      COPY_COLOR(successor, current);
      SET_COUNT(successor, GET_COUNT(current));
   }
   current->left= current->right= current->parent= NULL;
   SET_COLOR_BLACK(current);
   SET_COUNT(current, 0);
}

/** PruneLeaf performs pruning of nodes with at most one child node.
 * This is the real heart of node deletion.
 * The first operation is to decrease the node count from node to root_sentinel.
 */
void PruneLeaf( $nd *node ) {
   $nd *parent= node->parent, *current, *sibling, *sentinel;
   bool leftside= (parent->left == node);
   sentinel= IS_SENTINEL(node->left)? node->left : node->right;
   
   // first, decrement the count from here to root_sentinel
   for (current= node; NOT_ROOTSENTINEL(current); current= current->parent)
      ADD_COUNT(current, -1);

   // if the node is red and has at most one child, then it has no child.
   // Prune it.
   if (IS_RED(node)) {
      if (leftside) parent->left= sentinel;
      else parent->right= sentinel;
      return;
   }

   // node is black here.  If it has a child, the child will be red.
   if (node->left != sentinel) {
      // swap with child
      SET_COLOR_BLACK(node->left);
      node->left->parent= parent;
      if (leftside) parent->left= node->left;
      else parent->right= node->left;
      return;
   }
   if (node->right != sentinel) {
      // swap with child
      SET_COLOR_BLACK(node->right);
      node->right->parent= parent;
      if (leftside) parent->left= node->right;
      else parent->right= node->right;
      return;
   }

   // Now, we have determined that node is a black leaf node with no children.
   // The tree must have the same number of black nodes along any path from root
   // to leaf.  We want to remove a black node, disrupting the number of black
   // nodes along the path from the root to the current leaf.  To correct this,
   // we must either shorten all other paths, or add a black node to the current
   // path.  Then we can freely remove our black leaf.
   // 
   // While we are pointing to it, we will go ahead and delete the leaf and
   // replace it with the sentinel (which is also black, so it won't affect
   // the algorithm).

   if (leftside) parent->left= sentinel; else parent->right= sentinel;

   sibling= (leftside)? parent->right : parent->left;
   current= node;

   // Loop until the current node is red, or until we get to the root node.
   // (The root node's parent is the root_sentinel, which will have a NULL parent.)
   while (IS_BLACK(current) && NOT_ROOTSENTINEL(parent)) {
      // If the sibling is red, we are unable to reduce the number of black
      //  nodes in the sibling tree, and we can't increase the number of black
      //  nodes in our tree..  Thus we must do a rotation from the sibling
      //  tree to our tree to give us some extra (red) nodes to play with.
      // This is Case 1 from the text
      if (IS_RED(sibling)) {
         SET_COLOR_RED(parent);
         SET_COLOR_BLACK(sibling);
         if (leftside) {
            RotateLeft(parent);
            sibling= parent->right;
         }
         else {
            RotateRight(parent);
            sibling= parent->left;
         }
         continue;
      }
      // sibling will be black here

      // If the sibling is black and both children are black, we have to
      //  reduce the black node count in the sibling's tree to match ours.
      // This is Case 2a from the text.
      if (IS_BLACK(sibling->right) && IS_BLACK(sibling->left)) {
         assert(NOT_SENTINEL(sibling));
         SET_COLOR_RED(sibling);
         // Now we move one level up the tree to continue fixing the
         // other branches.
         current= parent;
         parent= current->parent;
         leftside= (parent->left == current);
         sibling= (leftside)? parent->right : parent->left;
         continue;
      }
      // sibling will be black with 1 or 2 red children here

      // << Case 2b is handled by the while loop. >>

      // If one of the sibling's children are red, we again can't make the
      //  sibling red to balance the tree at the parent, so we have to do a
      //  rotation.  If the "near" nephew is red and the "far" nephew is
      //  black, we need to rotate that tree rightward before rotating the
      //  parent leftward.
      // After doing a rotation and rearranging a few colors, the effect is
      //  that we maintain the same number of black nodes per path on the far
      //  side of the parent, and we gain a black node on the current side,
      //  so we are done.
      // This is Case 4 from the text. (Case 3 is the double rotation)
      if (leftside) {
         if (IS_BLACK(sibling->right)) { // Case 3 from the text
            RotateRight( sibling );
            sibling= parent->right;
         }
         // now Case 4 from the text
         SET_COLOR_BLACK(sibling->right);
         assert(NOT_SENTINEL(sibling));
         COPY_COLOR(sibling, parent);
         SET_COLOR_BLACK(parent);

         current= parent;
         parent= current->parent;
         RotateLeft( current );
         return;
      }
      else {
         if (IS_BLACK(sibling->left)) { // Case 3 from the text
            RotateLeft( sibling );
            sibling= parent->left;
         }
         // now Case 4 from the text
         SET_COLOR_BLACK(sibling->left);
         assert(NOT_SENTINEL(sibling));
         COPY_COLOR(sibling, parent);
         SET_COLOR_BLACK(parent);

         current= parent;
         parent= current->parent;
         RotateRight( current );
         return;
      }
   }

   // Now, make the current node black (to fulfill Case 2b)
   // Case 4 will have exited directly out of the function.
   // If we stopped because we reached the top of the tree,
   //   the head is black anyway so don't worry about it.
   SET_COLOR_BLACK(current);
}
END

   $src .= <<"END" if $self->with_clear;

/** Mark all nodes as being not-in-tree, and possibly delete the objects that contain them.
 * DeleteProc is optional.  If given, it will be called on the 'Object' which contains the $nd.
 * obj_ofs is a negative (or zero) number of bytes offset from the $nd pointer to the containing
 * object pointer.  `ctx` is a user-defined context pointer to pass to the destructor.
 */
void ${ns}clear( $nd *root_sentinel, void (*destructor)(void *obj, void *ctx), int obj_ofs, void *ctx ) {
   $nd *current, *next;
   int from_left;
   // Delete in a depth-first post-traversal, because the node might not exist after
   // calling the destructor.
   if (!IS_ROOTSENTINEL(root_sentinel))
      return; /* this is API usage bug, but no way to report it */
   if (IS_SENTINEL(root_sentinel->left))
      return; /* tree already empty */
   current= root_sentinel->left;
   while (1) {
      check_left: // came from above, go down-left
         if (NOT_SENTINEL(current->left)) {
            current= current->left;
            goto check_left;
         }
      check_right: // came up from the left, go down-right
         if (NOT_SENTINEL(current->right)) {
            current= current->right;
            goto check_left;
         }
      zap_current: // came up from the right, kill the current node and proceed up
         next= current->parent;
         from_left= (next->left == current)? 1 : 0;
         SET_COUNT(current, 0);
         current->left= current->right= current->parent= NULL;
         if (destructor) destructor(PTR_OFS(current,obj_ofs), ctx);
         current= next;
         if (current == root_sentinel)
            break;
         else if (from_left)
            goto check_right;
         else
            goto zap_current;
   }
   root_sentinel->left= root_sentinel->right;
   SET_COLOR_BLACK(root_sentinel);
   SET_COUNT(root_sentinel, 0);
}

END

   $src .= <<"END" if $self->with_check;

static int CheckSubtree($nd *node, ${ns}compare_fn, ${cmp_ctx_decl}int, int *);

int ${ns}check_structure($nd *node, ${ns}compare_fn compare, ${cmp_ctx_decl}int cmp_pointer_ofs) {
   // If at root, check for root sentinel details
   if (node && !node->parent) {
      if (IS_RED(node) || IS_RED(node->left) || GET_COUNT(node) || GET_COUNT(node->right))
         return RBTREE_INVALID_ROOT;
      if (GET_COUNT(node->right) || IS_RED(node->right) || node->right->left != node->right
         || node->right->right != node->right)
         return RBTREE_INVALID_SENTINEL;
      if (node->left == node->right) return 0; /* empty tree, nothing more to check */
      if (node->left->parent != node)
         return RBTREE_INVALID_ROOT;
      node= node->left; /* else start checking at first real node */
   }
   int black_count;
   return CheckSubtree(node, compare, ${cmp_ctx_arg}cmp_pointer_ofs, &black_count);
}

int CheckSubtree($nd *node, ${ns}compare_fn compare, ${cmp_ctx_decl}int cmp_pointer_ofs, int *black_count) {
   // This node should be fully attached to the tree
   if (!node || !node->parent || !node->left || !node->right || !GET_COUNT(node))
      return RBTREE_INVALID_NODE;
   // Check counts.  This is an easy way to validate the relation to sentinels too
   if (GET_COUNT(node) != GET_COUNT(node->left) + GET_COUNT(node->right) + 1)
      return RBTREE_INVALID_COUNT;
   // Check node key order
   int left_black_count= 0, right_black_count= 0;
   if (NOT_SENTINEL(node->left)) {
      if (node->left->parent != node)
         return RBTREE_INVALID_NODE;
      if (IS_RED(node) && IS_RED(node->left))
         return RBTREE_INVALID_COLOR;
      if (compare(${cmp_ctx_arg}PTR_OFS(node->left, cmp_pointer_ofs), PTR_OFS(node, cmp_pointer_ofs)) > 0)
         return RBTREE_INVALID_ORDER;
      int err= CheckSubtree(node->left, compare, ${cmp_ctx_arg}cmp_pointer_ofs, &left_black_count);
      if (err) return err;
   }
   if (NOT_SENTINEL(node->right)) {
      if (node->right->parent != node)
         return RBTREE_INVALID_NODE;
      if (IS_RED(node) && IS_RED(node->right))
         return RBTREE_INVALID_COLOR;
      if (compare(${cmp_ctx_arg}PTR_OFS(node->right, cmp_pointer_ofs), PTR_OFS(node, cmp_pointer_ofs)) < 0)
         return RBTREE_INVALID_ORDER;
      int err= CheckSubtree(node->right, compare, ${cmp_ctx_arg}cmp_pointer_ofs, &right_black_count);
      if (err) return err;
   }
   if (left_black_count != right_black_count)
      return RBTREE_INVALID_COLOR;
   *black_count= left_black_count + (IS_BLACK(node)? 1 : 0);
   return 0;
}
END
   $self->_append($dest, $src);
   return $self;
}

sub _append {
   my ($self, $fname, $content)= @_;
   if (-e $fname && !$self->{_have_written}{$fname}) {
      rename($fname, $fname.'.old') or croak "rename: $!";
   }
   my $fh;
   open($fh, '>>:utf8', $fname)
      and (print $fh $content)
      and close $fh
      or croak "write($fname): $!";
   ++$self->{_have_written}{$fname};
}

# Build a C macro that evaluates to the integer difference between objetc address and field address
sub _make_object_field_offset_macro {
   my ($self, $obj_t, $field)= @_;
   $obj_t =~ s/^struct *//;
   my $macro_name= 'OFS_' . $obj_t . '_FIELD_' . $field;
   $macro_name =~ s/\W+//g;
   my $macro_value= "( ((char*) &((($obj_t *)(void*)10000)->$field)) - ((char*)10000) )";
   return ($macro_name, $macro_value);
}

sub write_wrapper {
   my ($self, $dest, %opts)= @_;
   my $typedefs= $opts{typedefs} || [];

   # Terminology:
   #  There is a Container of Objects,
   #  A Container holds a Tree of Nodes, where the Tree is a field of the Container struct
   #  and the Node is a field of the Object struct.  This way a Container can declare multiple
   #  trees of the same objects, each indexing on a different Key of the object.
   #  The Key is optional- if not specified the compare function operates on Objects.

   # The namespace refers to the namespace of the tree-node functions, not the namespace
   # of this wrapper.
   my $ns= $self->namespace;

   # The Node type refers to the red/black node defined above in ${ns}rbtree.h
   my $node_t= $self->node_type;

   # The object type refers to the type of things in the container
   my $obj_t= $opts{obj_t} or croak "'obj_t' required (type of Object in the Container, each which holds one tree node)";
   # need to know the name of the node-field within that object, which will be treed
   my $node= $opts{node_field} or croak "'node_field' required (name of $node_t field within $obj_t)";

   # C macro that finds the object pointer when given a node pointer
   my ($node_ofs_macro, $node_ofs_code)= $self->_make_object_field_offset_macro($obj_t, $node);
   my $node_to_obj= sub { "(($obj_t *)(((char*)$_[0]) - $node_ofs_macro))" };

   my $cmp= $opts{cmp} or croak "'cmp' required (name of compare function, which either compares Objects or Keys)";
   
   # Keys are optional.  If not provided, the compare function will compare whole objects
   my $key_t= $opts{key_t};
   my $key= $opts{key_field};
   croak "If comparing keys, require both 'key_t' and 'key_field'"
      if $key xor $key_t;

   # C macro that finds the key pointer when given a node pointer
   my $node_to_key= $node_to_obj;
   my ($key_ofs_macro, $key_ofs_code)= !$key? ('', undef)
      : $self->_make_object_field_offset_macro($obj_t, $key);

   # The tree (defined by root and leaf sentinel) gets wrapped in a struct to be included in the Container
   my $tree_t= $opts{tree_t};
   my $tree_s= $opts{tree_s} || do {
      my $s= $tree_t || "${obj_t}_${node}";
      $s =~ s/^struct *//;
      $s =~ s/_t(_|$)/$1/;
      $s;
   };
   $tree_t ||= ($self->use_typedefs? "${tree_s}_t" : "struct $tree_s");

   # All methods of the tree get a namespace prefix
   (my $tree_ns= $tree_t.'_') =~ s/_t_/_/;
   $tree_ns =~ s/^struct *//;

   # The "value type" is the type of parameter given to 'find'
   my $value_t= $opts{value_t} || $key_t || $obj_t.' *';  # value_t must be a pointer.  No way to check that since user might give a typedef
   my $value_t_is_pointer= $value_t =~ /\*/;

   my $code= <<"END";

/* Auto-Generated by @{[ ref $self ]} version @{[ $self->VERSION ]} on @{[ $self->timestamp ]} */

#define $node_ofs_macro $node_ofs_code
@{[ $key_ofs_macro? "#define $key_ofs_macro $key_ofs_code" : '' ]}

/* Tree of $obj_t sorted by $cmp @{[ $key? "on $key" : "" ]} */
struct $tree_s {
   $node_t root_sentinel;
   $node_t leaf_sentinel;
};
@{[ $tree_t !~ /^struct/? "typedef struct $tree_s $tree_t;" : "" ]}

/* Initialize the $tree_t structure */
static inline void ${tree_ns}init($tree_t *tree) {
   ${ns}init_tree(&tree->root_sentinel, &tree->leaf_sentinel);
}

static inline $obj_t *${tree_ns}root($tree_t *tree) {
   return tree->root_sentinel.left->count? @{[ $node_to_obj->("tree->root_sentinel.left") ]} : NULL;
}

/* Return the first element of the tree, in sort order. */
static inline $obj_t *${tree_ns}first($tree_t *tree) {
   $node_t *node= ${ns}node_left_leaf(tree->root_sentinel.left);
   return node? @{[ $node_to_obj->("node") ]} : NULL;
}

/* Return the last element of the tree, in sort order */
static inline $obj_t *${tree_ns}last($tree_t *tree) {
   $node_t *node= ${ns}node_right_leaf(tree->root_sentinel.left);
   return node? @{[ $node_to_obj->("node") ]} : NULL;
}

/* Return the previous element of the tree, in sort order. */
static inline $obj_t *${tree_ns}prev($obj_t *obj) {
   $node_t *node= ${ns}node_prev(&(obj->$node));
   return node? @{[ $node_to_obj->("node") ]} : NULL;
}

/* Return the next element of the tree, in sort order. */
static inline $obj_t *${tree_ns}next($obj_t *obj) {
   $node_t *node= ${ns}node_next(&(obj->$node));
   return node? @{[ $node_to_obj->("node") ]} : NULL;
}

static inline $obj_t *${tree_ns}left($obj_t *obj) {
   return obj->$node.left->count? @{[ $node_to_obj->("obj->$node.left") ]} : NULL;
}
static inline $obj_t *${tree_ns}right($obj_t *obj) {
   return obj->$node.right->count? @{[ $node_to_obj->("obj->$node.right") ]} : NULL;
}
static inline $obj_t *${tree_ns}parent($obj_t *obj) {
   return obj->$node.parent->count? @{[ $node_to_obj->("obj->$node.parent") ]} : NULL;
}

/* Insert an object into the tree */
static inline bool ${tree_ns}insert($tree_t *tree, $obj_t *obj) {
    return ${ns}node_insert(&(tree->root_sentinel), &(obj->$node), (int(*)(void*,void*)) $cmp, $key_ofs_macro - $node_ofs_macro);
}

/* Search for an object matching 'goal'.  Returns the object, or NULL if none match.
 * In a tree with duplicate values, this returns the lowest-indexed match.
 */
static inline $obj_t *${tree_ns}find($tree_t *tree, $value_t goal) {
   $node_t *first= NULL;
   return ${ns}node_search(tree->root_sentinel.left,
      @{[ $value_t_is_pointer? "goal" : "((void*)&goal)" ]},
      (int(*)(void*,void*)) $cmp, $key_ofs_macro - $node_ofs_macro,
      &first, NULL, NULL)?
      @{[ $node_to_obj->("first") ]} : NULL;
}

/* Find the first match, last match, and count of matches.
 * If there are no matches, first and last are set to the nodes before and after the goal,
 * or if no such node exists they will be set to NULL.
 */
static inline int ${tree_ns}find_all($tree_t *tree, $value_t goal, $obj_t **first, $obj_t **last) {
   int count;
   $node_t *n_first= NULL, *n_last= NULL;
   ${ns}node_search(tree->root_sentinel.left,
      @{[ $value_t_is_pointer? "goal" : "((void*)&goal)" ]},
      (int(*)(void*,void*)) $cmp, $key_ofs_macro - $node_ofs_macro,
      first? &n_first : NULL, last? &n_last : NULL, &count);
   if (first)   *first=   n_first?   @{[ $node_to_obj->("n_first") ]}   : NULL;
   if (last)    *last=    n_last?    @{[ $node_to_obj->("n_last") ]}    : NULL;
   return count;
}

END

   $code .= <<"END" if $self->with_index;

/* Return the number of objects in the tree. */
static inline size_t ${tree_ns}count($tree_t *tree) {
   return tree->root_sentinel.left->count;
}

/* Get the list index of a node */
static inline size_t ${tree_ns}elem_index($obj_t *obj) {
   return ${ns}node_index(&obj->$node);
}

/* Get the Nth element in the sorted list of the tree's elements. */
static inline $obj_t *${tree_ns}elem_at($tree_t *tree, size_t n) {
   $node_t *node= ${ns}node_child_at_index(tree->root_sentinel.left, n);
   return node? @{[ $node_to_obj->("node") ]} : NULL;
}

END

   $code .= <<"END" if $self->with_remove;

/* Remove an object from the tree.  This does not delete the object. */
static inline void ${tree_ns}remove($obj_t *obj) {
   ${ns}node_prune(&(obj->$node));
}

END

   $code .= <<"END" if $self->with_clear;

/* Efficiently clear a large tree by iterating bottom to top and running a destructor
 * on each node.  This avoids all the node removal operations. 
 */
static inline void ${tree_ns}clear($tree_t *tree, void (*destructor)($obj_t *obj, void *opaque), void *opaque) {
   ${ns}clear(&tree->root_sentinel, (void (*)(void *, void *)) destructor, - $node_ofs_macro, opaque);
}

END

   $code .= <<"END" if $self->with_check;

/* Validate all known properties of the tree.  Returns 0 on success, an error code otherwise. */
static inline int ${tree_ns}check($tree_t *tree) {
   if (tree->root_sentinel.parent || tree->root_sentinel.count)
      return RBTREE_INVALID_ROOT;
   return ${ns}check_structure(&tree->root_sentinel, (int(*)(void*,void*)) $cmp, $key_ofs_macro - $node_ofs_macro);
}

END

   $self->_append($dest, $code);
   return $self;
}

1;
