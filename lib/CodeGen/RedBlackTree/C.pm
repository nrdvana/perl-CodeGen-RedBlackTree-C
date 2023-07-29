package CodeGen::RedBlackTree::C;
use v5.26;
use experimental 'signatures';
use warnings;
use Carp;
use Config;

# ABSTRACT: Generate C code for custom Red/Black Trees
our $VERSION; # VERSION

=head1 SYNOPSIS

  my $rbgen= Lang::Generate::RedBlackTree::C->new(
    namespace         => 'mytree_',
    cmp               => 'numeric',
    key_type          => 'uint64_t',
  );
  $rbgen->generate_rb_api->write('mytree.h', 'mytree.c');

=head1 DESCRIPTION

This module writes customizable Red/Black Tree algorithms as C source code.
While these sorts of things could be done with C header macros, I've decided
that is really a massive waste of time and wrote it as a perl module instead.

Why do you need to write custom tree algorithms?  Well, for starters, the same
reason C++ uses a template for C<std::map>, so that it can bake the item key
and comparison function directly into the code for better performance.

But additionally, this module lets you select features for

=over

=item The 'parent' pointer

This allows effecient iteration and deletion, but costs one extra pointer per
node.

=item Sub-tree 'count'

Storing a count of sub-nodes at each node lets you fetch the Nth element of
the collection in O(log(n)) time.  This is useful for finding a Median.

=item Color-packing

The red/black flag only requires one bit of storage.  You can pack it into the
LSB of one of your pointers. (since they point to aligned data and don't use
the low bits)  Doing this costs a bit of performance, but saves one int per
node.

=item Nesting Node Structs in User Data

If you declare a node as a field in your own struct, you can avoid allocating
separate tree nodes as you add your structs to a tree.  You also avoid needing
a 'data' pointer in the node, by doing offset math from the node pointer to the
containing struct.

=item Relative Keys

If a node's key is stored as an offset from its parent's key, you can
efficiently "move" a range of nodes along a linear axis in C<log(n)> time.
This is useful for editing sparse arrays.

=back

The attributes below can be passed to the constructor to control the code
generation.  

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
   if (defined $args{cmp} && !defined $args{key_type}) {
      if ($args{cmp} =~ /int|size_t/) {
         $args{key_type}= $args{cmp};
         $args{cmp}= 'numeric';
      } elsif ($args{cmp} =~ /^(numeric|relative)$/) {
         $args{key_type}= 'double';
      } elsif ($args{cmp} =~ /str.*cmp/) {
         $args{key_type}= 'const char *';
      } elsif ($args{cmp} ne 'callback') {
         croak "key_type must be defined when cmp is '$args{cmp}'";
      }
   }
   bless \%args, $class;
}

=head1 ATTRIBUTES

=head2 namespace

For C output, this prefixes each function and data type with a string, such as "rbtree_".

=head2 cmp

The algorithm that will be used for comparing nodes to determine their sort order.

=over

=item C<'numeric'>

Numeric comparison of keys using "<" and ">" operators.

=item C<< /int/ >>

Alias for 'numeric' that sets key_type at the same time.

=item C<'relative'>

Keys will be placement within a numeric domain, and stored relative to the parent node
such that they recalculate when the tree rotates, and a segment of the tree can be shifted
in O(log(n)) time.

=item C<'callback'>

Each time nodes need compared, it will invoke a callback, providing it pointers to the
key.  The callback gets one additional parameter which you configure per-tree.

=item C<'strcmp'>

Keys will be pointers, compared by passing them to strcmp.  Default key_type will be
C<< const char* >>.

=item I<*>

Any other string you provide will be treated as the name of a function that takes two
keys by value (of whatever L</key_type> is) and returns an int in the style of C<strcmp>.
You must specify L</key_type>.

=back

=head2 key_type

Declare the key type, which will then be part of the node.  Don't declare this if you use
C<< cmp => 'callback' >> and don't require a 'key' field in the node, such as if your key
is found in the user data.

=cut

sub namespace      { $_[0]{namespace} || 'rbtree_' }
sub cmp            { $_[0]{cmp} || 'callback' }
sub key_type       { $_[0]{key_type} }

=head2 tree_type

Type name for the tree struct.  This can be C<< struct ${namespace}tree >>,
or a typedef for the struct like C<< ${namespace}tree_t >>.  If you want to use a typedef
for I<a pointer to> the struct, prefix this attribute with '*'.

=head2 tree_struct

Type name for the struct underlying the L</tree_type>.  You can initialize this to whatever
you like, else it defaults to something sensible.

=head2 node_type

The type name of the red/black node.  This can be C<< struct ${namespace}tree >> to use
struct types throughout, or a typedef for the struct like C<< ${namespace}tree_t >>.
If you want to use a typedef for I<a pointer to> the struct, prefix this attribute with '*'.

=head2 node_struct

Type name for the struct underlying the L</node_type>.  You can initialize this to whatever
you like, else it defaults to something sensible.

=head2 node_data_type

The type name of user-data the node references.  This must be a pointer.
The default is C<< void* >>, resulting in generic code that you can cast as needed.

=head2 node_fields

This is a hashref for overriding the names of the fields within the node.

  {
    left   => ..., # left subtree
    right  => ..., # right subtree
    parent => ..., # subtree parent, only used if with_parent enabled
    color  => ..., # red/black (1/0), used unless with_packed_color specified
    count  => ..., # number of nodes in subtree, if with_count feature enabled
    key    => ..., # key or pointer to key, if key_type declared
    data   => ..., # pointer to user data, present if with_data_pointer feature enabled
  }

You can call this as a method with a list of field names, and it returns that same
list with any overrides applied.

  my ($left, $right, $parent)= $self->node_fields(qw( left right parent ));

=cut

sub tree_type         { $_[0]{tree_type} || undef }
sub tree_struct($self) {
   $self->{tree_struct}? $self->{tree_struct}
   : ($self->tree_type//'') =~ /^struct (\w+)/? $1
   : $self->namespace . 'tree'
}
# tree_type can be a struct typedef or pointer typedef.
# This figures out which, and returns the pointer type.
sub _tree_pointer_type($self) {
   my $typename= $self->tree_type || $self->namespace . 'tree_t';
   return $typename =~ /^[*]/? substr($typename,1) : $typename . '*';
}

sub node_type         { $_[0]{node_type} || undef }
sub node_struct($self) {
   $self->{node_struct}? $self->{node_struct}
   : ($self->node_type//'') =~ /^struct (\w+)/? $1
   : $self->namespace . 'node';
}
# node_type can be a struct typedef or pointer typedef.
# This figures out which, and returns the pointer type.
sub _node_pointer_type($self) {
   my $typename= $self->node_type || $self->namespace . 'node_t';
   # If starts with '*', then it is a typedef that already indicates a pointer.
   return $typename =~ /^[*]/? substr($typename,1) : $typename . '*';
}

sub node_data_type    { $_[0]{node_data_type} || undef }
sub node_fields($self, @list) {
   @list? (map +($self->{node_fields}{$_} // $_), @list)
   : ($self->{node_fields})
}

=head2 with_parent

Include parent-pointers in each node.  This feature costs an extra pointer per node, but
enables many useful features like efficient duplicate key handling and relative keys.

=head2 with_count

Include a count of sub-nodes on each node, which allows you to find the Nth node in the tree
in O(log(n)) time.  This comes at a very small performance cost when modifying the tree

=head2 with_data_pointer

Whether to include a pointer to user data within the node.  The default is true.  If set to
false, it is assumed you will use pointer math to reach the user data from the node pointer.

=head2 with_packed_color

Store the color bit inside the 'right' pointer, instead of giving it its own field.  This
costs a few instructions per access of the 'right' pointer making tree traversal and
modification a tiny bit slower.  This also assumes all nodes will be at least word-aligned.

=head2 with_inline

Whether to declare inline functions in the public header file for the simplest accessors.
If false, all public API will be compiled as normal extern functions.

=cut

sub with_parent       { $_[0]{with_parent} // 1 }
sub with_count        { $_[0]{with_count} // 1 }
sub with_data_pointer { $_[0]{with_data_pointer} // 1 }
sub with_packed_color { $_[0]{with_packed_color} }
sub with_inline       { $_[0]{with_inline} // 1 }

=head2 public_api_decl

C declaration of Calling API for public functions.  Defaults to 'extern'.

=head2 c_types

  ...->new( c_types => { ptrdiff_t => 'long long', bool => 'int' } )

  my ($size_t, $ptrdiff_t)= $rbgen->c_types(qw( size_t ptrdiff_t ));  

A hashref of overrides for C type names that this module uses in generated code.

If you call this as a method with a list of arguments, it returns that same list with any
overrides from this hash applied.

=head2 c_sizeof

  ...->new( c_sizeof => { size_t => 8 } )

This module needs C<sizeof(size_t)> if it bit-splices 'count' and 'color', and this can't
be determined with macros, so you need to find out from something like autoconf and cofigure
it here.

=cut

sub public_api_decl { $_[0]{public_api_decl} // 'extern' }

sub c_types($self, @list) {
   @list? (map +($self->{c_types}{$_} // $_), @list)
   : ($self->{c_types});
}

sub c_sizeof($self, @list) {
   my $sizeof= $self->{c_sizeof} //= {};
   $sizeof->{size_t} //= $Config{sizesize};
   @list? (map +($sizeof->{$_} // $_), @list)
   : $sizeof;
}

=head2 src_h

The cumulative lines of C header code from calls to C<generate_*>,
as an arrayref.

=head2 src_c

The cumulative lines of C implementation code generated by calls to C<generate_*>,
as an arrayref.

=cut

sub src_h             { $_[0]{src_h} ||= [] }
sub src_c             { $_[0]{src_c} ||= [] }

=head1 METHODS

=head2 write

  $rbgen->write($header_fname, $c_unit_fname);

This takes the accumulated L</src_h> and L</src_c> and writes them to the filenames you provide.
The files must not exist.  If anything goes wrong, it throws an error.  If any of the generated
code is Unicode, it is written as UTF-8.

Returns C<$self> for convenient chaining.

=cut

sub write($self, $h_dest, $c_dest) {
   _writefile($h_dest, join("\n", $self->src_h->@*)) if defined $h_dest;
   _writefile($c_dest, join("\n", $self->src_c->@*)) if defined $c_dest;
}
sub _writefile($dest, $content) {
   -e $dest and die "File exists: '$dest'";
   open my $fh, '>:encoding(UTF-8)', $dest or die "open($dest): $!";
   $fh->print($content)
      && $fh->close
      or die "write($dest): $!";
}

=head2 generate_rb_api

  $rbgen->generate_rb_api;

Generate all headers and implementation of the core Red/Black API, not including type-safe
wrappers.  Returns '$self' for convenient chaining.

This is a shortcut to call:

   * generate_node_struct
   * generate_implementation_util
   * generate_init_tree
   * generate_accessors
   * generate_insert

=cut

sub generate_rb_api($self) {
   $self->generate_node_struct;
   $self->generate_implementation_util;
   $self->generate_init_tree;
   $self->generate_accessors;
   $self->generate_insert;
   return $self;
}

=head2 generate_node_struct

Generate the R/B Tree and Node structs (and typedefs)

=cut

sub _if($cond, @items) {
   return $cond? @items : ();
}
sub _pad_to_same_len {
   my $max= List::Util::max(map length, grep defined, @_);
   $_ .= ' 'x($max - length) for grep defined, @_;
}

sub generate_node_struct($self) {
   my ($is_typedef, $struct_name, $typedef_varname);
   my ($bool, $ptrdiff_t, $uintptr_t, $size_t)= $self->c_types(qw( bool ptrdiff_t uintptr_t size_t));
   my ($size_sz)= $self->c_sizeof(qw( size_t ));
   my $ns= $self->namespace;
   my $node_ptr_t= $self->_node_pointer_type;
   my $node_struct= $self->node_struct;
   my $node_t= $node_ptr_t =~ /\*$/? substr($node_ptr_t, 0, -1) : 'struct '.$node_struct;
   my $node_typedef= ($node_ptr_t =~ /^struct /)? undef
      : ($node_ptr_t =~ /( *\*)$/)? substr($node_ptr_t, 0, -length $1)
      : '*'.$node_ptr_t;
   my $tree_ptr_t= $self->_tree_pointer_type;
   my $tree_struct= $self->tree_struct;
   my $tree_typedef= ($tree_ptr_t =~ /^struct /)? undef
      : ($tree_ptr_t =~ /( *\*)$/)? substr($tree_ptr_t, 0, -length $1)
      : '*'.$tree_ptr_t;
   my $key_t= $self->key_type // '';
   my $data_t= $self->node_data_type // 'void*';
   my ($left, $right, $parent, $data, $color, $count, $key)
      = $self->node_fields(qw( left right parent data color count key ));
   # If key_t ends with a bit splice, move the splice onto the key field name
   if ($key_t =~ /(.*?)(:\d+)/) {
      $key .= $2;
      $key_t= $1;
   }
   _pad_to_same_len($size_t, $node_ptr_t, $key_t, $data_t, $key_t, $data_t);
   my $h= join "\n",
      _if( $node_typedef,              "struct $node_struct;",
                                       "typedef struct $node_struct $node_typedef;" ),
                                       "struct $node_struct {",
                                       "   $node_ptr_t $left;",
      _if( !$self->with_packed_color,  "   $node_ptr_t $right;" ),
      _if( $self->with_packed_color,   "   $uintptr_t $right; // LSB is 0=black, 1=red" ),
      _if( $self->with_parent,         "   $node_ptr_t $parent;" ),
      _if( $self->with_data_pointer,   "   $data_t $data; // pointer to user data" ),
      _if( !$self->with_packed_color,  "   $size_t $color : 1; // black=0, red=1" ),
      _if( $self->with_count,          "   $size_t $count : @{[ $size_sz * 8 - 1 ]}; // number of subnodes" ),
      _if( defined $self->key_type,    "   $key_t $key;" ),
                                       "};",
      _if( $self->cmp eq 'callback',   "typedef int (*${ns}compare_fp)(void *context, void *key_a, void *key_b);" ),
                                       "struct $tree_struct {",
                                       "   $node_t root_sentinel; // parent node of root node of tree",
                                       "   $node_t leaf_sentinel; // child node of all leaf nodes",
      _if( !$self->with_data_pointer,  "   $ptrdiff_t node_to_data_ofs; // offset from node to user-data" ),
      _if( !defined $self->key_type,   "   $ptrdiff_t data_to_key_ofs; // offset from user-data to key passed to callback" ),
      _if( $self->cmp eq 'callback',   "   ${ns}compare_fp cmp; // compare two keys",
                                       "   void* cmp_context;   // first argument passed to cmp" ),
                                       "};",
      _if( $tree_typedef,              "typedef struct $tree_struct $tree_typedef;" ),
      '';
   push $self->src_h->@*, $h;
   $self;
}

=head2 generate_init_tree

This is the "constructor" of sorts.  It just initializes a tree struct which must be allocated
by the caller.

=cut

sub generate_init_tree($self) {
   my $api= $self->public_api_decl;
   my $ns= $self->namespace;
   my $np= $self->_node_pointer_type;
   my $tp= $self->_tree_pointer_type;
   my @args= ("$tp tree");
   push @args, 'ptrdiff_t node_to_data' if !$self->with_data_pointer;
   push @args, "ptrdiff_t data_to_key"  if !defined $self->key_type;
   push @args, "${ns}compare_fp cmp",
               "void* cmp_context"      if $self->cmp eq 'callback';
   my $callback_args= join ', ', @args;
   my $h= <<~C;
      /* Initialize a tree. Caller manages object lifespan */
      $api void ${ns}init_tree( $callback_args );
      C
   my $c= join "\n", <<~C,
      void ${ns}init_tree( $callback_args ) {
         SET_LEFT(&tree->root_sentinel, &tree->leaf_sentinel);
         SET_RIGHT(&tree->root_sentinel, &tree->leaf_sentinel);
         SET_COLOR_BLACK(&tree->root_sentinel);
         SET_COUNT(&tree->root_sentinel, 0);
         SET_PARENT(&tree->root_sentinel, NULL);
         
         SET_LEFT(&tree->leaf_sentinel, &tree->leaf_sentinel);
         SET_RIGHT(&tree->leaf_sentinel, &tree->leaf_sentinel);
         SET_COLOR_BLACK(&tree->leaf_sentinel);
         SET_COUNT(&tree->leaf_sentinel, 0);
         SET_PARENT(&tree->leaf_sentinel, &tree->leaf_sentinel);
      C
      _if( !$self->with_data_pointer,  "   tree->node_to_data_ofs= node_to_data;" ),
      _if( !defined $self->key_type,   "   tree->data_to_key_ofs= data_to_key;" ),
      _if( $self->cmp eq 'callback',   "   tree->cmp= cmp;",
                                       "   tree->cmp_context= cmp_context;" ),
      "}\n";
   push $self->src_h->@*, $h;
   push $self->src_c->@*, $c;
   $self;
}

=head2 generate_implementation_macros

Generates macros that are only seen/used in the source file.

=cut

sub _c_node_right($self, $node='node') {
   my $np= $self->_node_pointer_type;
   my ($right)= $self->node_fields('right');
   my ($uintptr_t)= $self->c_types('uintptr_t');
   $self->with_packed_color? "(($np)(($node)->$right & ~($uintptr_t)1))"
   : "(($node)->$right)"
}

sub _c_node_color($self, $node='node') {
   my $np= $self->_node_pointer_type;
   my ($right, $color)= $self->node_fields('right','color');
   $self->with_packed_color? "(($node)->$right & 1)"
   : "(($node)->$color)"
}

sub generate_implementation_util($self) {
   my ($left, $right, $color, $parent, $count, $data, $key)
      = $self->node_fields(qw( left right color parent count data key ));
   my ($uintptr_t, $bool, $size_t)
      = $self->c_types(qw( uintptr_t bool size_t ));
   my $np= $self->_node_pointer_type;
   my $c= <<~C;
      // Max conceivable depth of a correct Red/Black tree is
      // log2(max number of nodes) * 2 + 1
      #define NODE_STACK_LIMIT (62*2+1)
      #define NODE_LEFT(node)                      ((node)->$left)
      #define NODE_RIGHT(node)                     ${\ $self->_c_node_right }
      #define NODE_COLOR(node)                     ${\ $self->_c_node_color }
      #define NODE_IS_IN_TREE(node)                (($bool) (node)->$left)
      #define IS_LEAFSENTINEL(node)                ((node)->$left == (node))
      #define NOT_LEAFSENTINEL(node)               ((node)->$left != (node))
      #define CONTAINER_OFS_TO_FIELD(ctype, field) ( ((char*) &(((ctype)2048)->field)) - ((char*)2048) )
      #define CONTAINER_OF_FIELD(ctype, field, fp) ((ctype)( ((char*)fp) - CONTAINER_OFS_TO_FIELD(ctype, field) ))
      #define PTR_OFS(node,ofs)                    ((void*)( ((char*)(void*)(node))+ofs ))
      #define SET_LEFT(node, l)                    (NODE_LEFT(node)= l)
      #define IS_RED(node)                         NODE_COLOR(node)
      #define IS_BLACK(node)                       (!IS_RED(node))
      C
   # The color is either the low bit of the 'right' pointer, or its own field.
   $c .= $self->with_packed_color? <<~C1 : <<~C2;
      #define SET_COLOR_BLACK(node)    ((node)->$right &= ~($uintptr_t)1);
      #define SET_COLOR_RED(node)      ((node)->$right |= 1))
      #define COPY_COLOR(dest, src)    ((dest)->$right = ((dest)->$right & ~($uintptr_t)1) | ((src)->$right & 1))
      #define SET_RIGHT(node, r)       ((node)->$right = ($uintptr_t)r | ((node)->$right & 1))
      C1
      #define SET_COLOR_BLACK(node)    ((node)->$color= 0)
      #define SET_COLOR_RED(node)      ((node)->$color= 1)
      #define COPY_COLOR(dest,src)     ((dest)->$color= (src)->$color)
      #define SET_RIGHT(node, r)       ((node)->$right= (r))
      C2
   # these macros are needed for traversing upward when not using a top-down algorithm.
   $c .= $self->with_parent? <<~C1 : <<~C2;
      #define IS_ROOTSENTINEL(node)    (!($bool) (node)->$parent)
      #define NOT_ROOTSENTINEL(node)   (($bool) (node)->$parent)
      #define NODE_PARENT(node)        ((node)->$parent)
      #define SET_PARENT(node, p)      ((node)->$parent= (p))
      C1
      #define NODE_PARENT(node)        ((void)0)
      #define SET_PARENT(node, p)      ((void)0)
      C2
   $c .= $self->with_count? <<~C1 : <<~C2;
      #define GET_COUNT(node)          ((node)->$count)
      #define SET_COUNT(node,val)      ((node)->$count= (val))
      #define ADD_COUNT(node,val)      ((node)->$count+= (val))
      C1
      #define GET_COUNT(node)          ((void)0)
      #define SET_COUNT(node,val)      ((void)0)
      #define ADD_COUNT(node,val)      ((void)0)
      C2
   $c .= $self->with_data_pointer? <<~C1 : <<~C2;
      #define NODE_DATA(node)          ((node)->$data)
      C1
      #define NODE_DATA(node)          (((char*)node) + tree_node_to_data_ofs)
      C2
   $c .= $self->key_type? <<~C1 : <<~C2;
      #define NODE_KEY(node)           ((node)->$key)
      #define NODE_KEY_P(node)         (&((node)->$key))
      C1
      #define NODE_KEY_P(node)         (((char*)NODE_DATA(node)) + tree_data_to_key_ofs)
      #define NODE_KEY(node)           ((void)0) // can't access without knowing its type
      C2
   $c .= <<~C;
      static void rotate_right($np *node_stack) {
         $np node= node_stack[0];
         $np parent= node_stack[-1];
         $np new_head= NODE_LEFT(node);

         if (NODE_LEFT(parent) == node) SET_LEFT(parent, new_head);
         else SET_RIGHT(parent, new_head);
         SET_PARENT(new_head, parent);

         ADD_COUNT(node, -1 - GET_COUNT(NODE_LEFT(new_head)));
         ADD_COUNT(new_head, 1 + GET_COUNT(NODE_RIGHT(node)));
         SET_LEFT(node, NODE_RIGHT(new_head));
         SET_PARENT(NODE_RIGHT(new_head), node);

         SET_RIGHT(new_head, node);
         SET_PARENT(node, new_head);
         node_stack[0]= new_head;
      }

      static void rotate_left($np *node_stack) {
         $np node= node_stack[0];
         $np parent= node_stack[-1];
         $np new_head= NODE_RIGHT(node);

         if (NODE_LEFT(parent) == node) SET_LEFT(parent, new_head);
         else SET_RIGHT(parent, new_head);
         SET_PARENT(new_head, parent);

         ADD_COUNT(node, -1 - GET_COUNT(NODE_RIGHT(new_head)));
         ADD_COUNT(new_head, 1 + GET_COUNT(NODE_LEFT(node)));
         SET_RIGHT(node, NODE_LEFT(new_head));
         SET_PARENT(NODE_LEFT(new_head), node);

         SET_LEFT(new_head, node);
         SET_PARENT(node, new_head);
         node_stack[0]= new_head;
      }
      
      /* Re-balance a tree which has just had one element added.
       * node_stack[cur] is the parent node of the node just added.  The child is red.
       * Node counts and/or relative keys are corrected as rotations occur.
       * node_stack[0] always refers to the parent-sentinel.
       */
      static void balance( $np *node_stack, $size_t cur ) {
         // node_stack[0] is the root sentinel, and node_stack[1] is the root.
         // If the root is red we just swap it to black, so nothing to do unless
         // we are below the root.  Also, if current is a black node, no rotations needed
         while (cur > 1 && IS_RED(node_stack[cur])) {
            // current is red, the imbalanced child is red, and parent is black.
            $np current= node_stack[cur];
            $np parent= node_stack[cur-1];
            // if the current is on the left of the parent, the parent is to the right
            if (NODE_LEFT(parent) == current) {
               // if the sibling is also red, we can pull down the color black from the parent
               if (IS_RED(NODE_RIGHT(parent))) {
                  SET_COLOR_BLACK(NODE_RIGHT(parent));
                  SET_COLOR_BLACK(current);
                  SET_COLOR_RED(parent);
               }
               else {
                  // if the imbalance (red node) is on the right, and the parent is on the right,
                  //  need to rotate those nodes over to this side.
                  if (IS_RED(NODE_RIGHT(current)))
                     rotate_left(node_stack+cur);
                  // Now we can do our right rotation to balance the tree.
                  rotate_right(node_stack+cur-1);
                  SET_COLOR_RED(parent);
                  SET_COLOR_BLACK(node_stack[cur-1]);
                  return;
               }
            }
            // else the parent is to the left
            else {
               // if the sibling is also red, we can pull down the color black from the parent
               if (IS_RED(NODE_LEFT(parent))) {
                  SET_COLOR_BLACK(NODE_LEFT(parent));
                  SET_COLOR_BLACK(current);
                  SET_COLOR_RED(parent);
               }
               else {
                  // if the imbalance (red node) is on the left, and the parent is on the left,
                  //  need to rotate those nodes over to this side.
                  if (IS_RED(NODE_LEFT(current)))
                     rotate_right(node_stack+cur);
                  // Now we can do our left rotation to balance the tree.
                  rotate_left(node_stack+cur-1);
                  SET_COLOR_RED(parent);
                  SET_COLOR_BLACK(node_stack[cur-1]);
                  return;
               }
            }
            // jump twice up the tree. if current reaches the HeadSentinel (black node), we're done
            cur -= 2;
         }
         // now set the root node to be black
         SET_COLOR_BLACK(NODE_LEFT(node_stack[0]));
         return;
      }
      C
   push $self->src_c->@*, $c;
   $self;
}

=head2 generate_accessors

Generate various accessors for the tree nodes.

=cut

sub generate_accessors($self) {
   my ($left, $right, $color, $parent, $data)= $self->node_fields(qw( left right color parent data ));
   my ($bool)= $self->c_types(qw( bool ));
   my $ns= $self->namespace;
   my $np= $self->_node_pointer_type;
   my $tp= $self->_tree_pointer_type;
   my $data_t= $self->node_data_type // 'void*';
   my $treep= $self->_tree_pointer_type;
   my $api= $self->public_api_decl;
   my $inline= $self->with_inline? 'inline' : $api;
   my $node_right= $self->_c_node_right;
   my $node_color= $self->_c_node_color;
   my $block_node_is_added= "{ return ($bool) node->$left; }";
   my $block_node_color=    "{ return $node_color; }";
   my $block_node_left=     "{ return node->$left && node->$left->$left != node->$left? node->$left : NULL; }";
   my $block_node_right=    "{ $np right= $node_right; return right && right->$left != right? right : NULL; }";
   my $block_node_parent=   "{ return node->$parent && node->$parent->$parent? node->$parent : NULL; }";
   my $block_node_data= $self->with_data_pointer
                          ? "{ return node->$data; }"
                          : "{ return ($data_t)( ((char*)node) + ${ns}node_tree(node)->node_to_data_ofs ); }";
   my $h= <<~C;
      /* Quick test for whether an initialized node has been added to the tree */
      $inline $bool ${ns}node_is_added( $np node ) @{[ $inline eq $api? ";" : $block_node_is_added ]}
      
      /* Returns the tree this node belongs to, or NULL.  This is O(log(n)) */
      $api $tp ${ns}node_tree( $np node );
      
      /* red=true, black=false */
      $inline $bool ${ns}node_color( $np node ) @{[ $inline eq $api? ";" : $block_node_color ]}
      
      /* Return root of left subtree, or NULL */
      $inline $np ${ns}node_left( $np node ) @{[ $inline eq $api? ";" : $block_node_left ]}
      
      /* Return root of right subtree, or NULL */
      $inline $np ${ns}node_right( $np node ) @{[ $inline eq $api? ";" : $block_node_right ]}
      
      /* Returns right-most child of this node, or NULL */
      $api $np ${ns}node_right_leaf( $np node );
      
      /* Returns left-most child of this node, or NULL */
      $api $np ${ns}node_left_leaf( $np node );
      
      /* Return the user-data pointer of a node@{[ $self->with_data_pointer? "" : ". Warning: log(n) operation" ]}*/
      $inline $data_t ${ns}node_data( $np node ) @{[ $inline eq $api? ";" : $block_node_data ]}
      
      C
   my $c= <<~C;
      $tp ${ns}node_tree( $np node ) {
         if (!NODE_LEFT(node) || !NODE_RIGHT(node))
            return NULL;
         while (!IS_LEAFSENTINEL(node))
            node= NODE_LEFT(node);
         // Pointer math to get to tree which owns this leafsentinel
         return CONTAINER_OF_FIELD($tp, leaf_sentinel, node);
      }
      $np ${ns}node_left_leaf( $np node ) {
         if (IS_LEAFSENTINEL(node) || IS_LEAFSENTINEL(NODE_LEFT(node)))
            return NULL;
         while (NOT_LEAFSENTINEL(NODE_LEFT(node)))
            node= NODE_LEFT(node);
         return node;
      }
      $np ${ns}node_right_leaf( $np node ) {
         if (IS_LEAFSENTINEL(node) || IS_LEAFSENTINEL(NODE_RIGHT(node)))
            return NULL;
         while (NOT_LEAFSENTINEL(NODE_RIGHT(node)))
            node= NODE_RIGHT(node);
         return node;
      }
      C
   $c .= <<~C;
      $bool ${ns}node_is_added($np node) @{[ $inline eq $api? $block_node_is_added : ";" ]}
      $np ${ns}node_left($np node) @{[ $inline eq $api? $block_node_left : ";" ]}
      $np ${ns}node_right($np node) @{[ $inline eq $api? $block_node_right : ";" ]}
      $bool ${ns}node_color($np node) @{[ $inline eq $api? $block_node_color : ";" ]}
      $data_t ${ns}node_data($np node) @{[ $inline eq $api? $block_node_data : ";" ]}
      C
   $h .= <<~C if $self->with_parent;
      /* Return tree which contains this subtree, or NULL at root of tree */
      $inline $np ${ns}node_parent( $np node ) @{[ $inline eq $api? ";" : $block_node_parent ]}
      
      /* Return previous node in left-to-right sequence */
      $api $np ${ns}node_prev( $np node );
      
      /* Return next node in left-to-right sequence */
      $api $np ${ns}node_next( $np node );
      C
   $c .= <<~C if $inline eq $api && $self->with_parent;
      $np ${ns}node_parent(node) $block_node_parent
      C
   $c .= <<~C if $self->with_parent;
      $np ${ns}node_prev( $np node ) {
         if (IS_LEAFSENTINEL(node) || !NODE_IS_IN_TREE(node))
            return NULL;
         // If we are not at a leaf, move to the right-most node
         //  in the tree to the left of this node.
         if (NOT_LEAFSENTINEL(NODE_LEFT(node))) {
            node= NODE_LEFT(node);
            while (NOT_LEAFSENTINEL(NODE_RIGHT(node)))
               node= NODE_RIGHT(node);
            return node;
         }
         // Else walk up the tree until we see a parent node to the left
         else {
            $np parent= NODE_PARENT(node);
            if (!parent || IS_ROOTSENTINEL(parent))
               return NULL;
            while (NODE_LEFT(parent) == node) {
               node= parent;
               parent= NODE_PARENT(parent);
               if (IS_ROOTSENTINEL(parent))
                  return NULL;
            }
            return parent;
         }
      }
      $np ${ns}node_next( $np node ) {
         if (IS_LEAFSENTINEL(node) || !NODE_IS_IN_TREE(node))
            return NULL;
         // If we are not at a leaf, move to the left-most node
         //  in the tree to the right of this node.
         if (NOT_LEAFSENTINEL(NODE_RIGHT(node))) {
            node= NODE_RIGHT(node);
            while (NOT_LEAFSENTINEL(NODE_LEFT(node)))
               node= NODE_LEFT(node);
            return node;
         }
         // Else walk up the tree until we see a parent node to the right
         else {
            $np parent= NODE_PARENT(node);
            if (!parent || IS_ROOTSENTINEL(parent))
               return NULL;
            while (NODE_RIGHT(parent) == node) {
               node= parent;
               parent= NODE_PARENT(parent);
               if (IS_ROOTSENTINEL(parent))
                  return NULL;
            }
            return parent;
         }
      }
      C
   push $self->src_h->@*, $h;
   push $self->src_c->@*, $c;
   $self;
}

sub generate_insert($self) {
   my $api= $self->public_api_decl;
   my ($bool, $size_t)= $self->c_types(qw( bool size_t ));
   my $ns= $self->namespace;
   my $np= $self->_node_pointer_type;
   my $tp= $self->_tree_pointer_type;
   my $compare= $self->cmp eq 'numeric'? "NODE_KEY(node) - NODE_KEY(next)"
      : $self->cmp eq 'relative'? "NODE_KEY(node) -= NODE_KEY(next)"
      : $self->cmp eq 'callback'? "(tree->cmp)(tree->cmp_context, node_key_p, NODE_KEY_P(next))"
      : $self->cmp =~ /^\w+$/? $self->cmp."(NODE_KEY(node), NODE_KEY(next))"
      : croak "Unhandled comparison mode '".$self->cmp."'";
   my $h= <<~C1;
      /* Insert a node */
      $api $bool ${ns}tree_insert($tp tree, $np node);
      C1
   my $c= <<~C1;
      $bool ${ns}tree_insert($tp tree, $np node) {
         $np node_stack[NODE_STACK_LIMIT];
         @{[ $self->cmp eq 'callback' and
            "void* node_key_p= NODE_KEY_P(node);\\n"
        ."   ptrdiff_t tree_data_to_key_ofs= tree->data_to_key_ofs;"
         ]}
         // Can't insert node if it is already in the tree
         if (NODE_IS_IN_TREE(node))
            return false;
         $size_t cur= 0;
         node_stack[cur]= &tree->root_sentinel;
         int cmp= -1;
         $np next= NODE_LEFT(node_stack[cur]);
         while (NOT_LEAFSENTINEL(next)) {
            if (++cur >= NODE_STACK_LIMIT)
               return false;
            node_stack[cur]= next;
            cmp= $compare;
            next= (cmp < 0)? NODE_LEFT(next) : NODE_RIGHT(next);
         }
         if (cmp < 0) {
            SET_LEFT(node_stack[cur], node);
         } else {
            SET_RIGHT(node_stack[cur], node);
         }
         SET_PARENT(node, node_stack[cur]);
         SET_LEFT(node, &tree->leaf_sentinel);
         SET_RIGHT(node, &tree->leaf_sentinel);
         SET_COLOR_RED(node);
         
         // Update tree counts
         SET_COUNT(node, 1);
         for ($size_t i=0; i <= cur; i++)
            ADD_COUNT(node_stack[i], 1);
         
         balance(node_stack, cur);
         return true;
      }
      C1
   push $self->src_h->@*, $h;
   push $self->src_c->@*, $c;
   $self;
}

sub generate_find($self) {
   
}

1;
__END__

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

=cut

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
}


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