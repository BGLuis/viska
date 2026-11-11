import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Campo de texto Dark-Tech Editorial de alta precisão.
class ViskaTextField extends StatelessWidget {
  const ViskaTextField({
    super.key,
    this.controller,
    this.hintText,
    this.labelText,
    this.errorText,
    this.helperText,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.readOnly = false,
    this.enabled = true,
    this.autofocus = false,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
  });

  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final String? errorText;
  final String? helperText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool obscureText;
  final bool readOnly;
  final bool enabled;
  final bool autofocus;
  final int? maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (labelText != null) ...[
          Text(
            labelText!,
            style: ViskaTypography.labelMedium.copyWith(
              color: errorText != null ? ViskaColors.dangerDefault : ViskaColors.textSecondary,
            ),
          ),
          const SizedBox(height: ViskaSpacing.spaceXs),
        ],
        TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          enabled: enabled,
          readOnly: readOnly,
          obscureText: obscureText,
          maxLines: maxLines,
          minLines: minLines,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          style: ViskaTypography.bodyMedium.copyWith(
            color: enabled ? ViskaColors.textPrimary : ViskaColors.textMuted,
          ),
          cursorColor: ViskaColors.trustDefault,
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: ViskaTypography.bodyMedium.copyWith(
              color: ViskaColors.textMuted,
            ),
            errorText: errorText,
            errorStyle: ViskaTypography.bodySmall.copyWith(
              color: ViskaColors.dangerDefault,
            ),
            helperText: helperText,
            helperStyle: ViskaTypography.bodySmall.copyWith(
              color: ViskaColors.textSecondary,
            ),
            filled: true,
            fillColor: enabled ? ViskaColors.bgSurfaceRaised : ViskaColors.bgSurface,
            prefixIcon: prefixIcon,
            suffixIcon: suffixIcon,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: ViskaSpacing.spaceLg,
              vertical: ViskaSpacing.spaceMd,
            ),
            border: OutlineInputBorder(
              borderRadius: ViskaRadii.borderMd,
              borderSide: const BorderSide(color: ViskaColors.borderDefault),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: ViskaRadii.borderMd,
              borderSide: const BorderSide(color: ViskaColors.borderDefault),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: ViskaRadii.borderMd,
              borderSide: const BorderSide(
                color: ViskaColors.trustDefault,
                width: 1.5,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: ViskaRadii.borderMd,
              borderSide: const BorderSide(color: ViskaColors.dangerDefault),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: ViskaRadii.borderMd,
              borderSide: const BorderSide(
                color: ViskaColors.dangerDefault,
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
